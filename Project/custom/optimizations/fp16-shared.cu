#include <cmath>
#include <iostream>
#include "gpu-new-forward.h"

#include "cuda_fp16.h"

#define TILE_WIDTH 16

__constant__ half Mc[64*64];

#define CUDA_ERROR(val) { check_err((val), __FILE__, __LINE__); }
inline void check_err(cudaError_t err, const char* const file, int line)
{
    if (err != cudaSuccess)
    {
        // std::cerr << cudaGetErrorString(err) << " " << file << ":" << line << std::endl;
        fprintf(stderr, "Got GPU Error: %s in file %s: line %d\n", cudaGetErrorString(err), file, line);
        exit(err);
    }
}

#define LAST_CUDA_ERROR() { checkLastErr(__FILE__, __LINE__); }
inline void checkLastErr(const char* const file, const int line)
{
    cudaError_t err{cudaGetLastError()};
    if (err != cudaSuccess)
    {
        fprintf(stderr, "Got GPU Error: %s in file %s: line %d\n", cudaGetErrorString(err), file, line);
        exit(err);
    }
}

__global__ void conv_forward_kernel(half *output, const half *input, const half *mask, const int Batch, const int Map_out, const int Channel, const int Height, const int Width, const int K)
{
    /*
    Modify this function to implement the forward pass described in Chapter 16.
    We have added an additional dimension to the tensors to support an entire mini-batch
    The goal here is to be correct AND fast.

    Function paramter definitions:
    output - output
    input - input
    mask - convolution kernel
    Batch - batch_size (number of images in x)
    Map_out - number of output feature maps
    Channel - number of input feature maps
    Height - input height dimension
    Width - input width dimension
    K - kernel height and width (K x K)
    */

    const int Height_out = Height - K + 1;
    const int Width_out = Width - K + 1;

    int shared_w = TILE_WIDTH + K - 1;
    extern __shared__ half Shared_in[];  //cover all input

    // (void)Height_out; // silence declared but never referenced warning. remove this line when you start working
    // (void)Width_out; // silence declared but never referenced warning. remove this line when you start working

    // We have some nice #defs for you below to simplify indexing. Feel free to use them, or create your own.
    // An example use of these macros:
    // float a = in_4d(0,0,0,0)
    // out_4d(0,0,0,0) = a

    #define out_4d(i3, i2, i1, i0) output[(i3) * (Map_out * Height_out * Width_out) + (i2) * (Height_out * Width_out) + (i1) * (Width_out) + i0]
    #define in_4d(i3, i2, i1, i0) input[(i3) * (Channel * Height * Width) + (i2) * (Height * Width) + (i1) * (Width) + i0]
    #define mask_4d(i3, i2, i1, i0) Mc[(i3) * (Channel * K * K) + (i2) * (K * K) + (i1) * (K) + i0] // read from constant memory
    #define shared_3d(i2, i1, i0) Shared_in[(i2) * (shared_w * shared_w) + (i1) * (shared_w) + i0] //read from shared memory

    // Insert your GPU convolution kernel code here
    int W_grid_out = ceil(1.0*Width_out/TILE_WIDTH);

    int m = blockIdx.x; // out channel
    int b = blockIdx.z; // batch

    int h_start = (blockIdx.y / W_grid_out) * TILE_WIDTH;
    int w_start = (blockIdx.y % W_grid_out) * TILE_WIDTH;

    int h_out = (blockIdx.y / W_grid_out) * TILE_WIDTH + threadIdx.y;
    int w_out = (blockIdx.y % W_grid_out) * TILE_WIDTH + threadIdx.x;

    // Load shared memory
    for (int c = 0; c < Channel; c++){
      for (int i = threadIdx.y; i < shared_w; i += TILE_WIDTH){
        for (int j = threadIdx.x; j < shared_w; j += TILE_WIDTH){
          if ((h_start + i < Height) && (w_start + j < Width)){
            shared_3d(c, i, j) = in_4d(b, c, h_start + i, w_start + j);
          }
        }
      }
    }
    __syncthreads();

    if ((h_out < Height_out) && (w_out < Width_out)){    
      half acc = 0.0;
      for (int c = 0; c < Channel; c++){
        for (int p = 0; p < K; p++){
          for (int q = 0; q < K; q++){
            acc = __hadd(acc, __hmul(shared_3d(c, threadIdx.y + p, threadIdx.x + q), mask_4d(m, c, p, q)));
          }
        }
      }
      out_4d(b, m, h_out, w_out) = acc;
    }

    #undef out_4d
    #undef in_4d
    #undef mask_4d
}

__global__ void float2half(const float* in_float, half* out_half, int size){
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  for (int i = idx; i < size; i += 32 * 1024){
    out_half[i] = __float2half(in_float[i]);
  }
}

__global__ void half2float(float* out_float, half* in_half, int size){
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  for (int i = idx; i < size; i += 32 * 1024){
    out_float[i] = __half2float(in_half[i]);
  }
}
	
__host__ void GPUInterface::conv_forward_gpu_prolog(const float *host_output, const float *host_input, const float *host_mask, float **device_output_ptr, float **device_input_ptr, float **device_mask_ptr, const int Batch, const int Map_out, const int Channel, const int Height, const int Width, const int K)
{
    // Allocate memory and copy over the relevant data structures to the GPU

    // We pass double pointers for you to initialize the relevant device pointers,
    //  which are passed to the other two functions.

    // Useful snippet for error checking
    // cudaError_t error = cudaGetLastError();
    // if(error != cudaSuccess)
    // {
    //     std::cout<<"CUDA error: "<<cudaGetErrorString(error)<<std::endl;
    //     exit(-1);
    // }

    const int Height_out = Height - K + 1;
    const int Width_out = Width - K + 1;

    int size_Input = Height * Width * Batch * Channel;
    int size_Kernel = K * K * Map_out * Channel;
    int size_Output = Height_out * Width_out * Batch * Map_out;

    CUDA_ERROR(cudaMalloc((void **) device_input_ptr, size_Input * sizeof(float)));
    CUDA_ERROR(cudaMalloc((void **) device_mask_ptr, size_Kernel * sizeof(float)));
    CUDA_ERROR(cudaMalloc((void **) device_output_ptr, size_Output * sizeof(float)));

    CUDA_ERROR(cudaMemcpy(*device_input_ptr, host_input, size_Input * sizeof(float), cudaMemcpyHostToDevice));
    CUDA_ERROR(cudaMemcpy(*device_mask_ptr, host_mask, size_Kernel * sizeof(float), cudaMemcpyHostToDevice));
}


__host__ void GPUInterface::conv_forward_gpu(float *device_output, const float *device_input, const float *device_mask, const int Batch, const int Map_out, const int Channel, const int Height, const int Width, const int K)
{
    // Set the kernel dimensions and call the kernel
    int W_grid = ceil(1.0*(Width - K + 1)/TILE_WIDTH);
    int H_grid = ceil(1.0*(Height - K + 1)/TILE_WIDTH);
    int Y = H_grid * W_grid;
    int shared_w = TILE_WIDTH + K - 1;

    const int Height_out = Height - K + 1;
    const int Width_out = Width - K + 1;

    int size_Input = Height * Width * Batch * Channel;
    int size_Kernel = K * K * Map_out * Channel;
    int size_Output = Height_out * Width_out * Batch * Map_out;

    /* first convert float to half */
    half* half_device_input;
    half* half_device_output;
    half* half_device_mask;

    CUDA_ERROR(cudaMalloc(&half_device_input, size_Input * sizeof(half)));
    CUDA_ERROR(cudaMalloc(&half_device_mask, size_Kernel * sizeof(half)));
    CUDA_ERROR(cudaMalloc(&half_device_output, size_Output * sizeof(half)));

    /* to make the dimension fits for all input size, we don't allocate grid dims relevant to input data size*/
    dim3 gridHalf(32, 1, 1);
    dim3 blockHalf(1024, 1, 1);

    float2half <<< gridHalf, blockHalf >>> (device_input, half_device_input, size_Input);
    cudaDeviceSynchronize();
    float2half <<< gridHalf, blockHalf >>> (device_mask, half_device_mask, size_Kernel);
    cudaDeviceSynchronize();

    CUDA_ERROR(cudaMemcpyToSymbol(Mc, half_device_mask, size_Kernel*sizeof(half), 0, cudaMemcpyDeviceToDevice));

    dim3 blockDim(TILE_WIDTH, TILE_WIDTH, 1);
    dim3 gridDim(Map_out, Y, Batch);
    conv_forward_kernel <<< gridDim, blockDim, Channel * shared_w * shared_w * sizeof(half)  >>> (half_device_output, half_device_input, half_device_mask, Batch, Map_out, Channel, Height, Width, K);
    cudaDeviceSynchronize();

    /* convert back to float */
    half2float <<< gridHalf, blockHalf >>> (device_output, half_device_output, size_Output);
    cudaDeviceSynchronize();

    CUDA_ERROR(cudaFree(half_device_input));
    CUDA_ERROR(cudaFree(half_device_mask));
    CUDA_ERROR(cudaFree(half_device_output));

    LAST_CUDA_ERROR();
}


__host__ void GPUInterface::conv_forward_gpu_epilog(float *host_output, float *device_output, float *device_input, float *device_mask, const int Batch, const int Map_out, const int Channel, const int Height, const int Width, const int K)
{
    // Copy the output back to host
    const int Height_out = Height - K + 1;
    const int Width_out = Width - K + 1;
    int size_Output = Height_out * Width_out * Batch * Map_out;
    CUDA_ERROR(cudaMemcpy(host_output, device_output, size_Output * sizeof(float), cudaMemcpyDeviceToHost));

    // Free device memory
    CUDA_ERROR(cudaFree(device_input));
    CUDA_ERROR(cudaFree(device_mask));
    CUDA_ERROR(cudaFree(device_output));
}


__host__ void GPUInterface::get_device_properties()
{
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);

    for(int dev = 0; dev < deviceCount; dev++)
    {
        cudaDeviceProp deviceProp;
        cudaGetDeviceProperties(&deviceProp, dev);

        std::cout<<"Device "<<dev<<" name: "<<deviceProp.name<<std::endl;
        std::cout<<"Computational capabilities: "<<deviceProp.major<<"."<<deviceProp.minor<<std::endl;
        std::cout<<"Max Global memory size: "<<deviceProp.totalGlobalMem<<std::endl;
        std::cout<<"Max Constant memory size: "<<deviceProp.totalConstMem<<std::endl;
        std::cout<<"Max Shared memory size per block: "<<deviceProp.sharedMemPerBlock<<std::endl;
        std::cout<<"Max threads per block: "<<deviceProp.maxThreadsPerBlock<<std::endl;
        std::cout<<"Max block dimensions: "<<deviceProp.maxThreadsDim[0]<<" x, "<<deviceProp.maxThreadsDim[1]<<" y, "<<deviceProp.maxThreadsDim[2]<<" z"<<std::endl;
        std::cout<<"Max grid dimensions: "<<deviceProp.maxGridSize[0]<<" x, "<<deviceProp.maxGridSize[1]<<" y, "<<deviceProp.maxGridSize[2]<<" z"<<std::endl;
        std::cout<<"Warp Size: "<<deviceProp.warpSize<<std::endl;
    }
}
