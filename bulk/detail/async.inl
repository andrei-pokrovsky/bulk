#include <thrust/detail/config.h>
#include <bulk/async.hpp>
#include <bulk/detail/closure.hpp>
#include <bulk/detail/group_task.hpp>
#include <bulk/detail/throw_on_error.hpp>
#include <thrust/detail/minmax.h>
#include <thrust/system/cuda/detail/detail/uninitialized.h>
#include <thrust/system/cuda/detail/runtime_introspection.h>
#include <thrust/system/cuda/detail/cuda_launch_config.h>
#include <thrust/system/cuda/detail/synchronize.h>
#include <thrust/detail/util/blocking.h>

namespace bulk
{
namespace detail
{

using thrust::system::cuda::detail::detail::uninitialized;


template<typename Function>
__global__
void launch_by_value(uninitialized<Function> f)
{
  f.get()();
}


template<typename Function>
__global__
void launch_by_pointer(const Function *f)
{
  // copy to registers
  Function f_reg = *f;
  f_reg();
}


template<typename ThreadGroup, typename Closure>
struct launcher
{
  typedef group_task<ThreadGroup, Closure> task_type;

  typedef void (*global_function_t)(uninitialized<task_type>);

  template<typename LaunchConfig>
  future<void> go(LaunchConfig l, Closure c)
  {
    l.configure(c);

    if(l.num_groups() > 0 && l.num_threads_per_group() > 0)
    {
      task_type task(c, l.num_smem_bytes_per_group());

      uninitialized<task_type> wrapped_task;
      wrapped_task.construct(task);

      cudaEvent_t before_event;
      throw_on_error(cudaEventCreateWithFlags(&before_event, cudaEventDisableTiming | cudaEventBlockingSync), "cudaEventCreateWithFlags in launcher::go");
      throw_on_error(cudaStreamWaitEvent(l.stream(), before_event, 0), "cudaStreamWaitEvent in launcher::go");
      throw_on_error(cudaEventDestroy(before_event), "cudaEventDestroy in launcher::go");

      launch_by_value<<<
        static_cast<unsigned int>(l.num_groups()),
        static_cast<unsigned int>(l.num_threads_per_group()),
        static_cast<size_t>(l.num_smem_bytes_per_group()),
        l.stream()
      >>>(wrapped_task);

      thrust::system::cuda::detail::synchronize_if_enabled("bulk_kernel_by_value");
    } // end if

    return future_core_access::create_in_stream(l.stream());
  } // end go()

  static global_function_t get_global_function()
  {
    return launch_by_value<task_type>;
  } // end get_launch_function()
}; // end launcher


template<typename ThreadGroup, typename Function>
typename disable_if_static_thread_group<
  ThreadGroup,
  size_t
>::type
  choose_block_size(ThreadGroup g, Function f)
{
  namespace ns = thrust::system::cuda::detail;

  ns::function_attributes_t attr = ns::function_attributes(launcher<ThreadGroup,Function>::get_global_function());

  return ns::block_size_with_maximum_potential_occupancy(attr, ns::device_properties());
} // end choose_block_size()


template<typename ThreadGroup, typename Function>
size_t choose_smem_size(ThreadGroup g, Function f)
{
  namespace ns = thrust::system::cuda::detail;

  ns::function_attributes_t attr = ns::function_attributes(launcher<ThreadGroup,Function>::get_global_function());

  size_t occupancy =
    ns::cuda_launch_config_detail::max_active_blocks_per_multiprocessor(ns::device_properties(),
                                                                        attr,
                                                                        g.size(),
                                                                        0);

  return ns::proportional_smem_allocation(ns::device_properties(), attr, occupancy);
} // end choose_smem_size()


} // end detail


template<typename ThreadGroup>
  template<typename Function>
    void group_launch_config<ThreadGroup>
      ::configure(Function f,
                  typename disable_if_static_thread_group<
                    ThreadGroup,
                    Function
                  >::type *)
{
  if(num_threads_per_group() == use_default)
  {
    size_t block_size = detail::choose_block_size(m_example_group, f);

    m_example_group = ThreadGroup(block_size);

    m_num_groups = thrust::detail::util::divide_ri(m_num_threads, num_threads_per_group());
  } // end if

  if(m_num_smem_bytes_per_group == use_default)
  {
    m_num_smem_bytes_per_group = detail::choose_smem_size(m_example_group, f);
  } // end if
} // end launch::configure()


template<typename ThreadGroup>
  template<typename Function>
    void group_launch_config<ThreadGroup>
      ::configure(Function f,
                  typename enable_if_static_thread_group<
                    ThreadGroup,
                    Function
                  >::type *)
{
  if(m_num_smem_bytes_per_group == use_default)
  {
    m_num_smem_bytes_per_group = detail::choose_smem_size(m_example_group, f);
  } // end if
} // end launch::configure()


namespace detail
{


template<typename LaunchConfig, typename Closure>
future<void> async(LaunchConfig l, Closure c)
{
  detail::launcher<typename LaunchConfig::thread_group_type, Closure> launcher;
  return launcher.go(l, c);
} // end async()


} // end detail


template<typename LaunchConfig, typename Function>
future<void> async(LaunchConfig l, Function f)
{
  return detail::async(l, detail::make_closure(f));
} // end async()


template<typename LaunchConfig, typename Function, typename Arg1>
future<void> async(LaunchConfig l, Function f, Arg1 arg1)
{
  return detail::async(l, detail::make_closure(f,arg1));
} // end async()


template<typename LaunchConfig, typename Function, typename Arg1, typename Arg2>
future<void> async(LaunchConfig l, Function f, Arg1 arg1, Arg2 arg2)
{
  return detail::async(l, detail::make_closure(f,arg1,arg2));
} // end async()


template<typename LaunchConfig, typename Function, typename Arg1, typename Arg2, typename Arg3>
future<void> async(LaunchConfig l, Function f, Arg1 arg1, Arg2 arg2, Arg3 arg3)
{
  return detail::async(l, detail::make_closure(f,arg1,arg2,arg3));
} // end async()


template<typename LaunchConfig, typename Function, typename Arg1, typename Arg2, typename Arg3, typename Arg4>
future<void> async(LaunchConfig l, Function f, Arg1 arg1, Arg2 arg2, Arg3 arg3, Arg4 arg4)
{
  return detail::async(l, detail::make_closure(f,arg1,arg2,arg3,arg4));
} // end async()


template<typename LaunchConfig, typename Function, typename Arg1, typename Arg2, typename Arg3, typename Arg4, typename Arg5>
future<void> async(LaunchConfig l, Function f, Arg1 arg1, Arg2 arg2, Arg3 arg3, Arg4 arg4, Arg5 arg5)
{
  return detail::async(l, detail::make_closure(f,arg1,arg2,arg3,arg4,arg5));
} // end async()


} // end bulk

