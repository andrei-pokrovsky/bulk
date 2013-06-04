#include <moderngpu.cuh>
#include <thrust/scan.h>
#include <thrust/fill.h>
#include <thrust/device_vector.h>
#include <thrust/functional.h>
#include <thrust/random.h>
#include <cassert>
#include <iostream>
#include "time_invocation_cuda.hpp"
#include <thrust/detail/temporary_array.h>
#include <thrust/copy.h>
#include <bulk/bulk.hpp>


typedef int T;


template<unsigned int size, unsigned int grainsize>
struct inclusive_scan_n
{
  template<typename InputIterator, typename Size, typename OutputIterator, typename BinaryFunction>
  __device__ void operator()(bulk::static_thread_group<size,grainsize> &this_group, InputIterator first, Size n, OutputIterator result, BinaryFunction binary_op)
  {
    bulk::inclusive_scan(this_group, first, first + n, result, binary_op);
  }
};


template<unsigned int size, unsigned int grainsize>
struct exclusive_scan_n
{
  template<typename InputIterator, typename Size, typename OutputIterator, typename T, typename BinaryFunction>
  __device__ void operator()(bulk::static_thread_group<size,grainsize> &this_group, InputIterator first, Size n, OutputIterator result, T init, BinaryFunction binary_op)
  {
    bulk::exclusive_scan(this_group, first, first + n, result, init, binary_op);
  }
};


template<int NT, int VT, typename T, typename OutputIt>
__device__ void simple_copy_n(const T *source, int count, OutputIt dest)
{
  int tid = threadIdx.x;

  typedef typename std::iterator_traits<OutputIt>::value_type T2;

  #pragma unroll
  for(int i = 0; i < VT; ++i)
  {
    int index = NT * i + tid;
    if(index < count)
    {
      dest[NT * i + tid] = (T2)source[NT * i + tid];
    }
  }

  __syncthreads();
}


template<std::size_t size,
         std::size_t grainsize,
         typename RandomAccessIterator1,
         typename RandomAccessIterator2>
__forceinline__ __device__ void new_simple_copy_n(RandomAccessIterator1 first, int n, RandomAccessIterator2 result)
{
  typedef int size_type;
  size_type chunk_size = size * grainsize;

  int tid = threadIdx.x;

  for(RandomAccessIterator1 last = first + n;
      first < last;
      first += chunk_size, result += chunk_size)
  {
    // avoid conditional accesses when possible
    if((last - first) >= chunk_size)
    {
      #pragma unroll
      for(size_type i = 0; i < grainsize; ++i)
      {
        size_type idx = size * i + tid;
        result[idx] = first[idx];
      }
    }
    else
    {
      #pragma unroll
      for(size_type i = 0; i < grainsize; ++i)
      {
        size_type idx = size * i + tid;
        if(idx < (last - first)) result[idx] = first[idx];
      }
    }
  }

  __syncthreads();
}


template<typename Tuning, mgpu::MgpuScanType Type, typename InputIt, typename OutputIt, typename T, typename Op>
__global__ void my_KernelScanDownsweep(InputIt data_global, int count, int2 task, const T* reduction_global, OutputIt dest_global, bool totalAtEnd, Op op)
{
  typedef MGPU_LAUNCH_PARAMS Params;
  const int groupsize = Params::NT;
  const int grainsize = Params::VT;
  const int elements_per_group = groupsize * grainsize;

  bulk::static_thread_group<groupsize,grainsize> this_group;

  typedef typename Op::input_type input_type;
  typedef typename Op::value_type value_type;
  typedef typename Op::result_type result_type;
  
  typedef mgpu::CTAScan<groupsize, Op> S;
  union Shared {
    typename S::Storage scan;
    input_type  inputs[elements_per_group];
    value_type  values[elements_per_group];
    result_type results[elements_per_group];
  };
  __shared__ Shared shared;
  
  int tid = threadIdx.x;
  int block = blockIdx.x;
  int2 range = mgpu::ComputeTaskRange(block, task, elements_per_group, count);
  
  // reduction_global holds the exclusive scan of partials. This is undefined
  // for the first block.
  T next = reduction_global[block];
  bool nextDefined = 0 != block;
  
  while(range.x < range.y)
  {
    int count2 = min(elements_per_group, count - range.x);
    
    // Load from global to shared memory.
    mgpu::DeviceGlobalToShared<groupsize, grainsize>(count2, data_global + range.x, tid, shared.inputs);
    
    // Transpose out of shared memory.
    input_type inputs[grainsize];
    value_type values[grainsize];
    value_type x = op.Extract(op.Identity(), -1);
    
    #pragma unroll
    for(int i = 0; i < grainsize; ++i)
    {
      int index = grainsize * tid + i;
      if(index < count2)
      {
      	inputs[i] = shared.inputs[index];
      	values[i] = op.Extract(inputs[i], range.x + index);
      	x = i ? op.Plus(x, values[i]) : values[i];
      }
    }
    __syncthreads();
    
    // If nextTotal is defined (i.e. this is not the first frame in the
    // scan), add next into x, then add passTotal into next. Otherwise 
    // set total = passTotal.
    T passTotal;
    x = S::Scan(tid, x, shared.scan, &passTotal, mgpu::MgpuScanTypeExc, op);
    if(nextDefined)
    {
      x = op.Plus(next, x);
      next = op.Plus(next, passTotal);
    }
    else
    {
      next = passTotal;
    }
    
    #pragma unroll
    for(int i = 0; i < grainsize; ++i) 
    {
      int index = grainsize * tid + i;
      if(index < count2)
      {
        // If this is not the first element in the scan, add x values[i]
        // into x. Otherwise initialize x to values[i].
        value_type x2 = (i || tid || nextDefined) ? op.Plus(x, values[i]) : values[i];
        
        // For inclusive scan, set the new value then store.
        // For exclusive scan, store the old value then set the new one.
        if(mgpu::MgpuScanTypeInc == Type) x = x2;
        shared.results[index] = op.Combine(inputs[i], x);
        if(mgpu::MgpuScanTypeExc == Type) x = x2;
      }
    }
    __syncthreads();
    
    bulk::copy_n(this_group, shared.results, count2, dest_global + range.x);
    range.x += elements_per_group;
    nextDefined = true;
  }
  
  if(totalAtEnd && block == gridDim.x - 1 && !tid)
  {
    dest_global[count] = op.Combine(op.Identity(), next);
  }
}


template<mgpu::MgpuScanType Type, typename InputIt, typename OutputIt, typename Op>
void IncScan(InputIt data_global, int count, OutputIt dest_global, Op op, mgpu::CudaContext& context)
{
  typedef typename Op::value_type value_type;
  typedef typename Op::result_type result_type;
  
  const int threshold_of_parallelism = 20000;

  if(count < threshold_of_parallelism)
  {
    const int size = 512;
    const int grainsize = 3;

    bulk::static_thread_group<size,grainsize> group;
    bulk::async(bulk::par(group, 1), inclusive_scan_n<size,grainsize>(), bulk::there, data_global, count, dest_global, thrust::plus<int>());
  }
  else
  {
    // Run the parallel raking reduce as an upsweep.
    const int NT = 128;
    const int VT = 7;
    typedef mgpu::LaunchBoxVT<NT, VT> Tuning;
    int2 launch = Tuning::GetLaunchParams(context);
    const int NV = launch.x * launch.y;
    
    int numTiles = MGPU_DIV_UP(count, NV);
    int numBlocks = std::min(context.NumSMs() * 25, numTiles);
    int2 task = mgpu::DivideTaskRange(numTiles, numBlocks);
    
    MGPU_MEM(value_type) reductionDevice = context.Malloc<value_type>(numBlocks + 1);
    	
    mgpu::KernelReduce<Tuning><<<numBlocks, launch.x>>>(data_global, count, task, reductionDevice->get(), op);
    
    // Run a parallel latency-oriented scan to reduce the spine of the 
    // raking reduction.
    const unsigned int groupsize2 = 256;
    const unsigned int grainsize2 = 3;

    bulk::static_thread_group<groupsize2,grainsize2> group;
    bulk::async(bulk::par(group,1), exclusive_scan_n<groupsize2,grainsize2>(), bulk::there, reductionDevice->get(), numBlocks, reductionDevice->get(), 0, thrust::plus<int>());
    
    // Run a raking scan as a downsweep.
    my_KernelScanDownsweep<Tuning, Type><<<numBlocks, launch.x>>>(data_global, count, task, reductionDevice->get(), dest_global, false, op);
  }
}


template<typename InputIterator, typename OutputIterator>
OutputIterator my_inclusive_scan(InputIterator first, InputIterator last, OutputIterator result)
{
  mgpu::ContextPtr ctx = mgpu::CreateCudaDevice(0);

  ::IncScan<mgpu::MgpuScanTypeInc>(thrust::raw_pointer_cast(&*first),
                                   last - first,
                                   thrust::raw_pointer_cast(&*result),
                                   mgpu::ScanOp<mgpu::ScanOpTypeAdd,int>(),
                                   *ctx);

  return result + (last - first);
}


void my_scan(thrust::device_vector<T> *data)
{
  my_inclusive_scan(data->begin(), data->end(), data->begin());
}


void do_it(size_t n)
{
  thrust::host_vector<T> h_input(n);
  thrust::fill(h_input.begin(), h_input.end(), 1);

  thrust::host_vector<T> h_result(n);

  thrust::inclusive_scan(h_input.begin(), h_input.end(), h_result.begin());

  thrust::device_vector<T> d_input = h_input;
  thrust::device_vector<T> d_result(d_input.size());

  my_inclusive_scan(d_input.begin(), d_input.end(), d_result.begin());

  cudaError_t error = cudaDeviceSynchronize();

  if(error)
  {
    std::cerr << "CUDA error: " << cudaGetErrorString(error) << std::endl;
  }

  assert(h_result == d_result);
}


template<typename InputIterator, typename OutputIterator>
OutputIterator mgpu_inclusive_scan(InputIterator first, InputIterator last, OutputIterator result)
{
  mgpu::ContextPtr ctx = mgpu::CreateCudaDevice(0);

  mgpu::Scan<mgpu::MgpuScanTypeInc>(thrust::raw_pointer_cast(&*first),
                                    last - first,
                                    thrust::raw_pointer_cast(&*result),
                                    mgpu::ScanOp<mgpu::ScanOpTypeAdd,int>(),
                                    (int*)0,
                                    false,
                                    *ctx);

  return result + (last - first);
}


void sean_scan(thrust::device_vector<T> *data)
{
  mgpu_inclusive_scan(data->begin(), data->end(), data->begin());
}


int main()
{
  for(size_t n = 1; n <= 1 << 20; n <<= 1)
  {
    std::cout << "Testing n = " << n << std::endl;
    do_it(n);
  }

  thrust::default_random_engine rng;
  for(int i = 0; i < 20; ++i)
  {
    size_t n = rng() % (1 << 20);
   
    std::cout << "Testing n = " << n << std::endl;
    do_it(n);
  }

  thrust::device_vector<T> vec(1 << 24);

  sean_scan(&vec);
  double sean_msecs = time_invocation_cuda(50, sean_scan, &vec);

  my_scan(&vec);
  double my_msecs = time_invocation_cuda(50, my_scan, &vec);

  std::cout << "Sean's time: " << sean_msecs << " ms" << std::endl;
  std::cout << "My time: " << my_msecs << " ms" << std::endl;

  std::cout << "My relative performance: " << sean_msecs / my_msecs << std::endl;

  return 0;
}

