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


template<std::size_t groupsize, std::size_t grainsize>
struct inclusive_downsweep
{
  template<typename RandomAccessIterator1, typename RandomAccessIterator2, typename T, typename BinaryFunction>
  __device__ void operator()(bulk::static_thread_group<groupsize,grainsize> &this_group,
                             RandomAccessIterator1 first,
                             int count,
                             int2 task,
                             const T *carries,
                             RandomAccessIterator2 result,
                             BinaryFunction binary_op)
  {
    const int elements_per_group = groupsize * grainsize;
  
    int2 range = mgpu::ComputeTaskRange(this_group.index(), task, elements_per_group, count);
    
    // give group 0 a carry by taking the first input element
    // and adjusting its range
    T carry = (this_group.index() != 0) ? carries[this_group.index()-1] : first[0];
    if(this_group.index() == 0)
    {
      if(this_group.this_thread.index() == 0)
      {
        *result = carry;
      }
  
      ++range.x;
    }
  
    RandomAccessIterator1 last = first + range.y;
    first += range.x;
    result += range.x;
  
    bulk::detail::scan_detail::inclusive_scan_with_carry(this_group, first, last, result, carry, binary_op);
  }
};


template<std::size_t groupsize, std::size_t grainsize, typename RandomAccessIterator, typename Op>
struct buffer
{
  typedef union
  {
    typename mgpu::CTAReduce<groupsize,Op>::Storage             reduce;
    typename thrust::iterator_value<RandomAccessIterator>::type inputs[groupsize * grainsize];
  } type;
};


template<std::size_t groupsize, std::size_t grainsize, typename RandomAccessIterator, typename Op>
__device__
typename thrust::iterator_value<RandomAccessIterator>::type
  my_reduce_with_buffer(bulk::static_thread_group<groupsize,grainsize> &g,
                        RandomAccessIterator first,
                        RandomAccessIterator last,
                        Op op,
                        typename buffer<
                          groupsize, grainsize, RandomAccessIterator, Op
                        >::type *buffer)
{
  typedef mgpu::CTAReduce<groupsize, Op> R;
  typedef typename thrust::iterator_value<RandomAccessIterator>::type value_type;
  const int elements_per_group = groupsize * grainsize;

  // total is the sum of encountered elements. It's undefined on the first 
  // loop iteration.
  T total;
  bool totalDefined = false;
  
  // Loop through all tiles returned by ComputeTaskRange.
  for(; first < last; first += elements_per_group)
  {
    int count2 = thrust::min<int>(elements_per_group, last - first);
    
    // Read tile data into register.
    value_type inputs[grainsize];
    mgpu::DeviceGlobalToReg<groupsize, grainsize>(count2, first, g.this_thread.index(), inputs);
    
    if(Op::Commutative)
    {
      // This path exploits the commutative property of the operator.
      #pragma unroll
      for(int i = 0; i < grainsize; ++i)
      {
        int index = groupsize * i + g.this_thread.index();
        if(index < count2)
        {
          T x = inputs[i];
          total = (i || totalDefined) ? op.Plus(total, x) : x;
        }
      }
    }
    else
    {
      // Store the inputs to shared memory and read them back out in
      // thread order.
      mgpu::DeviceRegToShared<groupsize, grainsize>(elements_per_group, inputs, g.this_thread.index(), buffer->inputs);
      
      T x = op.Extract(op.Identity(), -1);			
      #pragma unroll
      for(int i = 0; i < grainsize; ++i)
      {
        int index = grainsize * g.this_thread.index() + i;
        if(index < count2)
        {
          T y = buffer->inputs[index];
          x = i ? op.Plus(x, y) : y;
        }
      }
      __syncthreads();
      
      // Run a CTA-wide reduction
      x = R::Reduce(g.this_thread.index(), x, buffer->reduce, op);
      total = totalDefined ? op.Plus(total, x) : x;
    }
    
    totalDefined = true;
  }  
  
  if(Op::Commutative)
  {
    // Run a CTA-wide reduction to sum the partials for each thread.
    total = R::Reduce(g.this_thread.index(), total, buffer->reduce, op);
  }

  return total;
}


template<std::size_t groupsize, std::size_t grainsize, typename RandomAccessIterator, typename Op>
__device__
typename thrust::iterator_value<RandomAccessIterator>::type
  my_reduce(bulk::static_thread_group<groupsize,grainsize> &this_group,
            RandomAccessIterator first,
            RandomAccessIterator last,
            Op op)
{
  typedef typename buffer<
    groupsize,
    grainsize,
    RandomAccessIterator,
    Op
  >::type buffer_type;
  
  buffer_type *buffer = reinterpret_cast<buffer_type*>(bulk::malloc(this_group, sizeof(buffer_type)));

  typename thrust::iterator_value<RandomAccessIterator>::type total
    = my_reduce_with_buffer(this_group, first, last, op, buffer);

  bulk::free(this_group,buffer);

  return total;
}


template<std::size_t groupsize, std::size_t grainsize>
struct reduce_tiles
{
  template<typename InputIterator, typename Op>
  __device__ void operator()(bulk::static_thread_group<groupsize,grainsize> &this_group,
                             InputIterator data_global,
                             int count,
                             int2 task,
                             typename Op::value_type *reduction_global,
                             Op op)
  {
    typedef typename Op::value_type value_type;
    
    int2 range = mgpu::ComputeTaskRange(this_group.index(), task, groupsize * grainsize, count);

    value_type total = my_reduce(this_group, data_global + range.x, data_global + range.y, op);

    if(this_group.this_thread.index() == 0)
    {
      reduction_global[this_group.index()] = total;
    }
  }
};


template<typename InputIt, typename OutputIt, typename Op>
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
    const int groupsize1 = 128;
    const int grainsize1 = 7;
    typedef mgpu::LaunchBoxVT<groupsize1, grainsize1> Tuning;
    int2 launch = Tuning::GetLaunchParams(context);
    const int NV = launch.x * launch.y;
    
    int numTiles = MGPU_DIV_UP(count, NV);
    int numBlocks = std::min(context.NumSMs() * 25, numTiles);
    int2 task = mgpu::DivideTaskRange(numTiles, numBlocks);
    
    MGPU_MEM(value_type) reductionDevice = context.Malloc<value_type>(numBlocks);
    	
    // N loads
    bulk::static_thread_group<groupsize1,grainsize1> reduce_group;
    bulk::async(bulk::par(reduce_group,numBlocks), reduce_tiles<groupsize1,grainsize1>(), bulk::there, data_global, count, task, reductionDevice->get(), op);
    
    // scan the sums to get the carries
    const unsigned int groupsize2 = 256;
    const unsigned int grainsize2 = 3;

    // XXX we could scatter the carries to the output instead of scanning in place
    //     this might simplify the next kernel
    bulk::static_thread_group<groupsize2,grainsize2> group2;
    bulk::async(bulk::par(group2,1), inclusive_scan_n<groupsize2,grainsize2>(), bulk::there, reductionDevice->get(), numBlocks, reductionDevice->get(), thrust::plus<int>());
    
    // do the downsweep - N loads, N stores
    bulk::static_thread_group<groupsize1,grainsize1> downsweep_group;
    bulk::async(bulk::par(downsweep_group,numBlocks), inclusive_downsweep<groupsize1,grainsize1>(), bulk::there, data_global, count, task, reductionDevice->get(), dest_global, thrust::plus<int>());
  }
}


template<typename InputIterator, typename OutputIterator>
OutputIterator my_inclusive_scan(InputIterator first, InputIterator last, OutputIterator result)
{
  mgpu::ContextPtr ctx = mgpu::CreateCudaDevice(0);

  ::IncScan(thrust::raw_pointer_cast(&*first),
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

  thrust::device_vector<T> vec(1 << 28);

  sean_scan(&vec);
  double sean_msecs = time_invocation_cuda(50, sean_scan, &vec);

  my_scan(&vec);
  double my_msecs = time_invocation_cuda(50, my_scan, &vec);

  std::cout << "Sean's time: " << sean_msecs << " ms" << std::endl;
  std::cout << "My time: " << my_msecs << " ms" << std::endl;

  std::cout << "My relative performance: " << sean_msecs / my_msecs << std::endl;

  return 0;
}

