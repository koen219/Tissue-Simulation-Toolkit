#include "pde.cpp"
//Allow the CPU implementation for the PDE solver when CUDA is enabled.
#include <cusparse.h>
#include <cuda_profiler_api.h>


#define ARRAY_SIZE 1
#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }

/*! \brief Check whether a GPU is available
*/
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

/*! \brief Assign the derivatives to solve for the CUDA reaction diffusion solver
  As an example, the PDE for secretion diffusion from vessel.cpp is implemented
  Any ODE system can be implemented here
  \param current_time The derivatives may be time dependent
  \param y Current values of the PDE variables
  \param dydt Vector that returns the derivatives at index id
  \param sigmalfield The current CPM configuration
  \param id The index for which the derivatives need to be computed
  \param secr_rate Vector of secretion rates
  \param decay_rate Vector of diffusion rates 
*/
__device__ void DerivativesPDE(PDEFIELD_TYPE current_time, PDEFIELD_TYPE* y, PDEFIELD_TYPE* dydt, int* sigmafield, int id, PDEFIELD_TYPE* secr_rate, PDEFIELD_TYPE* decay_rate ){
  int sigma = sigmafield[id];
  if (sigma > 0) {
    dydt[0] = secr_rate[0];
  } else {
    // outside cells
    dydt[0] = -decay_rate[0] * y[0];
  }
}

/*! \brief Error checking function for CUDA functions
  Can return synchronized and synchronized errors for CUDA code
*/
void cuErrorChecker(cudaError_t errSync, cudaError_t errAsync){
  errSync  = cudaGetLastError();
  errAsync = cudaDeviceSynchronize();
  if (errSync != cudaSuccess) 
    printf("Sync kernel error: %s\n", cudaGetErrorString(errSync));
  if (errAsync != cudaSuccess)
    printf("Async kernel error: %s\n", cudaGetErrorString(errAsync));
}

/*! \buffer size required for the horizontal ADI sweep*/
size_t pbuffersizeH; 
/*! \brief location alloted to the buffer for the horizontal ADI sweep on the GPU*/
void *pbufferH;
/*! \brief status of horizontal ADI sweep*/
cusparseStatus_t statusH; 
/*! \brief handle for the  horizontal ADI sweep*/
cusparseHandle_t handleH;
/*! \buffer size required for the vertical ADI sweep*/
size_t pbuffersizeV; 
/*! \brief location alloted to the buffer for the vertical ADI sweep on the GPU*/
void *pbufferV;
/*! \brief status of vertical ADI sweep*/
cusparseStatus_t statusV; 
/*! \brief handle for the  vertical ADI sweep*/
cusparseHandle_t handleV;


void PDE::InitialiseCuda(){
  cout << "Start cuda init" << endl;

  cudaMalloc((void**) &d_diffusioncoefficient, layers*sizex*sizey*sizeof(PDEFIELD_TYPE));
  cudaMalloc((void**) &d_celltype, sizex*sizey*sizeof(int));
  cudaMalloc((void**) &d_sigmafield, sizex*sizey*sizeof(int));

  cudaMalloc((void**) &d_PDEvars, layers*sizex*sizey*sizeof(PDEFIELD_TYPE));
  cudaMemcpy(d_PDEvars, PDEvars, layers*sizex*sizey*sizeof(PDEFIELD_TYPE), cudaMemcpyHostToDevice);
  cudaMalloc((void**) &d_alt_PDEvars, layers*sizex*sizey*sizeof(PDEFIELD_TYPE));
  cudaMemcpy(d_alt_PDEvars, alt_PDEvars, layers*sizex*sizey*sizeof(PDEFIELD_TYPE), cudaMemcpyHostToDevice);
  cudaMalloc((void**) &d_secr_rate, ARRAY_SIZE*sizeof(PDEFIELD_TYPE));
  cudaMemcpy(d_secr_rate, par.secr_rate.data(), ARRAY_SIZE*sizeof(PDEFIELD_TYPE), cudaMemcpyHostToDevice);
  cudaMalloc((void**) &d_decay_rate, ARRAY_SIZE*sizeof(PDEFIELD_TYPE));
  cudaMemcpy(d_decay_rate, par.decay_rate.data(), ARRAY_SIZE*sizeof(PDEFIELD_TYPE), cudaMemcpyHostToDevice);



  //Needed for ADI steps
  gpuErrchk(cudaMallocManaged(&upperH, sizex*sizey*sizeof(PDEFIELD_TYPE)));
  gpuErrchk(cudaMallocManaged(&diagH, sizex*sizey*sizeof(PDEFIELD_TYPE)));
  gpuErrchk(cudaMallocManaged(&lowerH, sizex*sizey*sizeof(PDEFIELD_TYPE)));
  gpuErrchk(cudaMallocManaged(&BH, sizex*sizey*sizeof(PDEFIELD_TYPE)));
  gpuErrchk(cudaMallocManaged(&upperV, sizey*sizex*sizeof(PDEFIELD_TYPE)));
  gpuErrchk(cudaMallocManaged(&diagV, sizey*sizex*sizeof(PDEFIELD_TYPE)));
  gpuErrchk(cudaMallocManaged(&lowerV, sizey*sizex*sizeof(PDEFIELD_TYPE)));
  gpuErrchk(cudaMallocManaged(&BV, sizey*sizex*sizeof(PDEFIELD_TYPE)));

  handleH = 0;
  pbuffersizeH = 0;
  pbufferH = NULL;
  statusH=cusparseCreate(&handleH);
  #ifdef PDEFIELD_DOUBLE
    cusparseDgtsvInterleavedBatch_bufferSizeExt(handleH, 0, sizex, lowerH, diagH, upperH, BH, sizey, &pbuffersizeH); //Compute required buffersize for horizontal sweep
  #else
    cusparseSgtsvInterleavedBatch_bufferSizeExt(handleH, 0, sizex, lowerH, diagH, upperH, BH, sizey, &pbuffersizeH); //Compute required buffersize for horizontal sweep
  #endif
  gpuErrchk(cudaMalloc( &pbufferH, sizeof(char)* pbuffersizeH));
  

  handleV = 0;
  pbuffersizeV = 0;
  pbufferV = NULL;
  statusV=cusparseCreate(&handleV);
  #ifdef PDEFIELD_DOUBLE
    cusparseDgtsvInterleavedBatch_bufferSizeExt(handleV, 0, sizey, lowerV, diagV, upperV, BV, sizex, &pbuffersizeV); //Compute required buffersize for vertical sweep
  #else
    cusparseSgtsvInterleavedBatch_bufferSizeExt(handleV, 0, sizey, lowerV, diagV, upperV, BV, sizex, &pbuffersizeV); //Compute required buffersize for vertical sweep
  #endif
  gpuErrchk(cudaMalloc( &pbufferV, sizeof(char)* pbuffersizeV));

  cout << "End cuda init" << endl;
}

/*! \Initialises the diagonals required for alternating direction implicit methods
    This initialises the tridiagonal diffusion matrices that are required for solving per row / column
    For Ax=b, this initialises the matrix A for every row and column
*/
__global__ void InitialiseDiagonals(int sizex, int sizey, PDEFIELD_TYPE twooverdt, PDEFIELD_TYPE dx2, PDEFIELD_TYPE* lowerH, PDEFIELD_TYPE* upperH, PDEFIELD_TYPE* diagH, PDEFIELD_TYPE* lowerV, PDEFIELD_TYPE* upperV, PDEFIELD_TYPE* diagV, PDEFIELD_TYPE* diffusioncoefficient){
  //This function could in theory be parellelized further, split into 6 (each part only assigning 1 value.), but this is probably slower
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int stride = blockDim.x * gridDim.x;
  int xloc; //position we currently want to assign to
  int yloc;
  int idcc; //id corresponding to the diffusioncoefficient (+sizey to get the value right, +1 to get the value above)
  for (int id = index; id < sizex*sizey; id += stride){
    xloc = id/sizey; //needed to obtain interleaved format
    yloc = id%sizey;
    idcc = xloc*sizey + yloc;
    if(xloc == 0){
      lowerH[id] = 0;
      diagH[id] = diffusioncoefficient[idcc+sizey]/dx2 + twooverdt;
      upperH[id] = -diffusioncoefficient[idcc+sizey]/dx2;  
    }
    else if(xloc == sizex -1){
      lowerH[id] = -diffusioncoefficient[idcc-sizey]/dx2;
      diagH[id] = diffusioncoefficient[idcc-sizey]/dx2 + twooverdt;
      upperH[id] = 0;
    }
    else{
      lowerH[id] = -diffusioncoefficient[idcc-sizey]/dx2;
      diagH[id] = (diffusioncoefficient[idcc+sizey]+diffusioncoefficient[idcc-sizey])/dx2 + twooverdt;
      upperH[id] = -diffusioncoefficient[idcc+sizey]/dx2;
    }

    xloc = id%sizex; //needed to obtain interleaved format
    yloc = id/sizex;
    idcc = xloc*sizey + yloc;
    if(yloc == 0){
      lowerV[id] = 0;
      diagV[id] = diffusioncoefficient[idcc+1]/dx2 + twooverdt;
      upperV[id] = -diffusioncoefficient[idcc+1]/dx2;
    }
    else if(yloc == sizey -1){
      lowerV[id] = -diffusioncoefficient[idcc-1]/dx2;
      diagV[id] = diffusioncoefficient[idcc-1]/dx2 + twooverdt;
      upperV[id] = 0;
    }
    else{
      lowerV[id] = -diffusioncoefficient[idcc-1]/dx2;
      diagV[id] = (diffusioncoefficient[idcc+1]+diffusioncoefficient[idcc-1])/dx2 + twooverdt;
      upperV[id] = -diffusioncoefficient[idcc+1]/dx2;
      
    }
  }
}

/*! \brief Intialises the righthandside vectors of the implicit ADI solver for rows
  For Ax=b, this initialises the vectorb b for every column
*/
__global__ void InitialiseHorizontalVectors(int sizex, int sizey, PDEFIELD_TYPE twooverdt, PDEFIELD_TYPE dx2, PDEFIELD_TYPE* BH, PDEFIELD_TYPE* diffusioncoefficient, PDEFIELD_TYPE* alt_PDEvars){
  
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int stride = blockDim.x * gridDim.x;
  int xloc;
  int yloc;
  int idcc; //id corresponding to the diffusioncoefficient and alt_PDEvars(+sizey to get the value right, +1 to get the value above)
  for (int id = index; id < sizex*sizey; id += stride){
    xloc = id/sizey; //needed to obtain interleaved format
    yloc = id%sizey;
    idcc = xloc*sizey + yloc;

    if (yloc == 0)
      BH[id] = twooverdt*alt_PDEvars[idcc] + (diffusioncoefficient[idcc+1]*(alt_PDEvars[idcc+1] - alt_PDEvars[idcc]))/dx2; 
    else if (yloc == sizey-1)
      BH[id] = twooverdt*alt_PDEvars[idcc] + (diffusioncoefficient[idcc-1]*(alt_PDEvars[idcc-1] - alt_PDEvars[idcc]))/dx2;  
    else
      BH[id] = twooverdt*alt_PDEvars[idcc] + (diffusioncoefficient[idcc+1]*(alt_PDEvars[idcc+1] - alt_PDEvars[idcc]) + diffusioncoefficient[idcc-1]*(alt_PDEvars[idcc-1] - alt_PDEvars[idcc]))/dx2;
  }
}

/*! \brief Intialises the righthandside vectors of the implicit ADI solver for columns
  For Ax=b, this initialises the vectorb b for every row
*/
__global__ void InitialiseVerticalVectors(int sizex, int sizey, PDEFIELD_TYPE twooverdt, PDEFIELD_TYPE dx2, PDEFIELD_TYPE* BV, PDEFIELD_TYPE* diffusioncoefficient, PDEFIELD_TYPE* alt_PDEvars){
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int stride = blockDim.x * gridDim.x;
  int xloc;
  int yloc;
  int idcc; //id corresponding to the diffusioncoefficient and alt_PDEvars(+sizey to get the value right, +1 to get the value above)
  for (int id = index; id < sizex*sizey; id += stride){
    xloc = id%sizex;
    yloc = id/sizex;
    idcc = xloc*sizey + yloc;

    if (xloc == 0)
      BV[id] = twooverdt*alt_PDEvars[idcc] + (diffusioncoefficient[idcc+sizey]*(alt_PDEvars[idcc+sizey] - alt_PDEvars[idcc]))/dx2; 
    else if (xloc == sizex-1)
      BV[id] = twooverdt*alt_PDEvars[idcc] + (diffusioncoefficient[idcc-sizey]*(alt_PDEvars[idcc-sizey] - alt_PDEvars[idcc]))/dx2;  
    else 
      BV[id] = twooverdt*alt_PDEvars[idcc] + (diffusioncoefficient[idcc+sizey]*(alt_PDEvars[idcc+sizey] - alt_PDEvars[idcc]) + diffusioncoefficient[idcc-sizey]*(alt_PDEvars[idcc-sizey] - alt_PDEvars[idcc]))/dx2;
  }

}


/*! \brief copy the solution of the first PDEvar layer by the horizontal ADI iteration back into PDE vars*/
__global__ void NewPDEfieldH0(int sizex, int sizey, PDEFIELD_TYPE* BH, PDEFIELD_TYPE* PDEvars){ //Take the values from BH and assign the new values of the first layers of PDEvars
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int stride = blockDim.x * gridDim.x;
  for (int id = index; id < sizex*sizey; id += stride){
    PDEvars[id] = BH[id];      
  }
}

/*! \brief copy the solution of the first PDEvar layer by the vertical ADI iteration back into PDE vars*/
__global__ void NewPDEfieldV0(int sizex, int sizey, PDEFIELD_TYPE* BV, PDEFIELD_TYPE* PDEvars){ //Take the values from BV and assign the new values of the first layers of PDEvars
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int stride = blockDim.x * gridDim.x;
  for (int id = index; id < sizex*sizey; id += stride){
    PDEvars[sizey*(id%sizex)+id/sizex] = BV[id]; //Conversion is needed because PDEvars iterates over columns first and then rows, while BV does the opposite 
  }
}


/*! \brief Copy all values of alt_PDEvars, except the first value after diffusion
  Only the first component of the PDEvars vector diffuses. This may be extended to 
  diffuse any or all chemicals in an analogous way.
*/
__global__ void NewPDEfieldOthers(int sizex, int sizey, int layers, PDEFIELD_TYPE* BH, PDEFIELD_TYPE* PDEvars, PDEFIELD_TYPE* alt_PDEvars){ //copy the other values from alt_PDEvars to PDEvars
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int stride = blockDim.x * gridDim.x;
  for (int id = 0; id < layers*sizex*sizey; id += stride){
    PDEvars[id] = alt_PDEvars[id]; 
  }
}


/*! \brief Perform forward Euler step for a total of dt time in steps of size ddt 
  The forward Euler steps are computed with time step ddt for a total of dt time
  par.ddt must therefore divide par.dt/2
  \param dt Total time for which the forward Euler steps are computed
  \param ddt Time steps in which time steps of a total of dt are computed
  \param layers Number of PDE variables
  \param sizex Grid size in x direction
  \param sizey Grid size in y direction
  \param PDEvars PDE variables at the start of the forward Euler steps
  \param alt_PDEvars Location where the new PDE vars need to be stored
  \param sigmafield Current CPM field
  \param secr_rate Secretion rates of chemicals
  \param decay_rate Decay rate of chemicals.
*/
__global__ void ODEstepFE(PDEFIELD_TYPE dt, PDEFIELD_TYPE ddt, double thetime, int layers, int sizex, int sizey, PDEFIELD_TYPE* PDEvars, PDEFIELD_TYPE* alt_PDEvars, 
                          int* sigmafield, PDEFIELD_TYPE* secr_rate, PDEFIELD_TYPE* decay_rate){
  
  int nr_of_iterations = round(dt/ddt);
  if (fabs(dt/ddt - nr_of_iterations) > 0.001)
    printf("dt and ddt do not divide properly!");
  if (nr_of_iterations == 0)
    printf("0 iterations!");
  PDEFIELD_TYPE stepsize;
  PDEFIELD_TYPE y[ARRAY_SIZE];
  PDEFIELD_TYPE dydt[ARRAY_SIZE];
  PDEFIELD_TYPE current_time;
  PDEFIELD_TYPE MaxTimeError = 5e-7;
  int i;

  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int stride = blockDim.x * gridDim.x;
  for (int id = index; id < sizex*sizey; id += stride){
    current_time = thetime;
    for (i=0;i<layers;i++)
      y[i]=PDEvars[i*sizex*sizey + id];
    for (int it = 0; it < nr_of_iterations; it++){
      DerivativesPDE(current_time,y,dydt, sigmafield,  id, secr_rate, decay_rate );
      current_time += ddt;
      if (it == nr_of_iterations-1) { //Are we done?
        for (i=0;i<layers;i++) {
          alt_PDEvars[i*sizex*sizey + id] = y[i]+ddt*dydt[i];
        }
      }
      else{ 
        for (i=0;i<layers;i++) {
          y[i]=y[i]+ddt*dydt[i];  
        }
      }
    }    
  }
}


/*! \brief Utitility function that copies alt_PDEvars to PDEvars
  \param sizex Grid size in x direction
  \param sizey Grid size in y direction
  \param layers Number of PDE variables
  \param PDEsource Source vector
  \param PDEtarget Target vector
*/
__global__ void CopyAltToOriginalPDEvars(int sizex, int sizey, int layers, PDEFIELD_TYPE* PDEsource, PDEFIELD_TYPE* PDEtarget){
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int stride = blockDim.x * gridDim.x;
  for (int id = index; id < layers*sizex*sizey; id += stride){
    PDEtarget[id] = PDEsource[id]; 
  }
}


void PDE::cuPDEsteps(CellularPotts * cpm, int repeat){
  //copy current diffusioncoefficient matrix and celltype matrix from host to device
  cudaError_t errSync;
  cudaError_t errAsync;
  sigmafield = cpm->getSigma(); 
  cudaMemcpy(d_diffusioncoefficient, DiffCoeffs[0][0], layers*sizex*sizey*sizeof(PDEFIELD_TYPE), cudaMemcpyHostToDevice); 
  cudaMemcpy(d_sigmafield, sigmafield[0], sizex*sizey*sizeof(int), cudaMemcpyHostToDevice);
  cudaMemcpy(d_PDEvars, PDEvars[0][0], layers*sizex*sizey*sizeof(PDEFIELD_TYPE), cudaMemcpyHostToDevice);
  cudaDeviceSynchronize();
  errSync  = cudaGetLastError();
  errAsync = cudaDeviceSynchronize(); 
  
  int nr_blocks = sizex*sizey/par.threads_per_core + 1;

  for (int iteration = 0; iteration < repeat/repeat; iteration++){

      //setup matrices for upperdiagonal, diagonal and lower diagonal for both the horizontal and vertical direction, since these remain the same during one PDE step
    InitialiseDiagonals<<<par.number_of_cores, par.threads_per_core>>>(sizex, sizey, 2/dt, dx2, lowerH, upperH, diagH, lowerV, upperV, diagV, d_diffusioncoefficient);
    cudaDeviceSynchronize();
    errSync  = cudaGetLastError();
    errAsync = cudaDeviceSynchronize();
    if (errSync != cudaSuccess) 
      printf("Sync kernel error: %s\n", cudaGetErrorString(errSync));
    if (errAsync != cudaSuccess)
      printf("Async kernel error: %s\n", cudaGetErrorString(errAsync));

    cuODEstep();
    cuHorizontalADIstep();
    thetime = thetime + dt/2;
    cuODEstep();
    cuVerticalADIstep();
    thetime = thetime + dt/2; 
 
  }
  cudaMemcpy(PDEvars[0][0], d_PDEvars, layers*sizex*sizey*sizeof(PDEFIELD_TYPE), cudaMemcpyDeviceToHost);
  cudaDeviceSynchronize();
}

void PDE::cuODEstep(){
  //Do an ODE step of size dt/2
  cudaError_t errSync;
  cudaError_t errAsync;
  ODEstepFE<<<par.number_of_cores, par.threads_per_core>>>(dt/2, ddt, thetime, layers, sizex, sizey, d_PDEvars, d_alt_PDEvars, d_sigmafield, d_secr_rate, d_decay_rate);
  cuErrorChecker(errSync, errAsync);
}

void PDE::cuHorizontalADIstep(){
  //Do a horizontal ADI sweep of size dt/2
  cudaError_t errSync;
  cudaError_t errAsync;
  InitialiseHorizontalVectors<<<par.number_of_cores, par.threads_per_core>>>(sizex, sizey, 2/dt, dx2, BH, d_diffusioncoefficient, d_alt_PDEvars);
  cuErrorChecker(errSync, errAsync);
  #ifdef PDEFIELD_DOUBLE
    statusH = cusparseDgtsvInterleavedBatch(handleH, 0, sizex, lowerH, diagH, upperH, BH, sizey, pbufferH);
  #else
    //statusH = cusparseSgtsvInterleavedBatch(handleH, 0, sizex, lowerH, diagH, upperH, BH, sizey, pbufferH);
  #endif
  if (statusH != CUSPARSE_STATUS_SUCCESS)
  {
    cout << statusH << endl;
  }
  NewPDEfieldH0<<<par.number_of_cores, par.threads_per_core>>>(sizex, sizey, BH, d_PDEvars);    
  cuErrorChecker(errSync, errAsync);
  NewPDEfieldOthers<<<par.number_of_cores, par.threads_per_core>>>(sizex, sizey, layers, BV, d_PDEvars, d_alt_PDEvars); //////
  cuErrorChecker(errSync, errAsync);

}

void PDE::cuVerticalADIstep(){
  //Do a vertical ADI sweep of size dt/2
  cudaError_t errSync;
  cudaError_t errAsync;
  InitialiseVerticalVectors<<<par.number_of_cores, par.threads_per_core>>>(sizex, sizey, 2/dt, dx2, BV, d_diffusioncoefficient, d_alt_PDEvars);
  cuErrorChecker(errSync, errAsync);
  #ifdef PDEFIELD_DOUBLE
    statusV = cusparseDgtsvInterleavedBatch(handleV, 0, sizey, lowerV, diagV, upperV, BV, sizex, pbufferV);
  #else
    statusV = cusparseSgtsvInterleavedBatch(handleV, 0, sizey, lowerV, diagV, upperV, BV, sizex, pbufferV);
  #endif
  if (statusV != CUSPARSE_STATUS_SUCCESS)
  {
    cout << statusV << endl;
  }
  cudaDeviceSynchronize();
  NewPDEfieldV0<<<par.number_of_cores, par.threads_per_core>>>(sizex, sizey, BV, d_PDEvars); //////
  errSync  = cudaGetLastError();
  errAsync = cudaDeviceSynchronize();
  if (errSync != cudaSuccess) 
    printf("Sync kernel error: %s\n", cudaGetErrorString(errSync));
  if (errAsync != cudaSuccess)
    printf("Async kernel error: %s\n", cudaGetErrorString(errAsync));
  NewPDEfieldOthers<<<par.number_of_cores, par.threads_per_core>>>(sizex, sizey, layers, BV, d_PDEvars, d_alt_PDEvars); //////
  cuErrorChecker(errSync, errAsync);

}

