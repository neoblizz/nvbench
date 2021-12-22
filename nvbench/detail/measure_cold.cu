/*
 *  Copyright 2021 NVIDIA Corporation
 *
 *  Licensed under the Apache License, Version 2.0 with the LLVM exception
 *  (the "License"); you may not use this file except in compliance with
 *  the License.
 *
 *  You may obtain a copy of the License at
 *
 *      http://llvm.org/foundation/relicensing/LICENSE.txt
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

#include <nvbench/detail/measure_cold.cuh>

#include <nvbench/benchmark_base.cuh>
#include <nvbench/device_info.cuh>
#include <nvbench/printer_base.cuh>
#include <nvbench/state.cuh>
#include <nvbench/summary.cuh>

#include <nvbench/detail/ring_buffer.cuh>
#include <nvbench/detail/throw.cuh>

#include <fmt/format.h>

#include <algorithm>
#include <cstdio>
#include <stdexcept>
#include <variant>

namespace nvbench::detail
{

measure_cold_base::measure_cold_base(state &exec_state)
    : m_state{exec_state}
    , m_run_once{exec_state.get_run_once()}
    , m_min_samples{exec_state.get_min_samples()}
    , m_max_noise{exec_state.get_max_noise()}
    , m_min_time{exec_state.get_min_time()}
    , m_skip_time{exec_state.get_skip_time()}
    , m_timeout{exec_state.get_timeout()}
{}

void measure_cold_base::check()
{
  const auto device = m_state.get_device();
  if (!device)
  {
    NVBENCH_THROW(std::runtime_error,
                  "{}",
                  "Device required for `cold` measurement.");
  }
  if (!device->is_active())
  { // This means something went wrong higher up. Throw an error.
    NVBENCH_THROW(std::runtime_error,
                  "{}",
                  "Internal error: Current device is not active.");
  }
}

void measure_cold_base::initialize()
{
  m_total_cuda_time = 0.;
  m_total_cpu_time  = 0.;
  m_cpu_noise       = 0.;
  m_total_samples   = 0;
  m_noise_tracker.clear();
  m_cuda_times.clear();
  m_cpu_times.clear();
  m_max_time_exceeded = false;
}

void measure_cold_base::run_trials_prologue() { m_walltime_timer.start(); }

void measure_cold_base::record_measurements()
{
  // Update and record timers and counters:
  const auto cur_cuda_time = m_cuda_timer.get_duration();
  const auto cur_cpu_time  = m_cpu_timer.get_duration();
  m_cuda_times.push_back(cur_cuda_time);
  m_cpu_times.push_back(cur_cpu_time);
  m_total_cuda_time += cur_cuda_time;
  m_total_cpu_time += cur_cpu_time;
  ++m_total_samples;

  // Compute convergence statistics using CUDA timings:
  const auto mean_cuda_time = m_total_cuda_time /
                              static_cast<nvbench::float64_t>(m_total_samples);
  const auto cuda_stdev =
    nvbench::detail::statistics::standard_deviation(m_cuda_times.cbegin(),
                                                    m_cuda_times.cend(),
                                                    mean_cuda_time);
  auto cuda_rel_stdev = cuda_stdev / mean_cuda_time;
  if (std::isfinite(cuda_rel_stdev))
  {
    m_noise_tracker.push_back(cuda_rel_stdev);
  }
}

bool measure_cold_base::is_finished()
{
  if (m_run_once)
  {
    return true;
  }

  // Check that we've gathered enough samples:
  if (m_total_cuda_time > m_min_time && m_total_samples > m_min_samples)
  {
    // Noise has dropped below threshold
    if (m_noise_tracker.back() < m_max_noise)
    {
      return true;
    }

    // Check if the noise (cuda rel stdev) has converged by inspecting a
    // trailing window of recorded noise measurements.
    // This helps identify benchmarks that are inherently noisy and would
    // never converge to the target stdev threshold. This check ensures that the
    // benchmark will end if the stdev stabilizes above the target threshold.
    // Gather some iterations before checking noise, and limit how often we
    // check this.
    if (m_noise_tracker.size() > 64 && (m_total_samples % 16 == 0))
    {
      // Use the current noise as the stdev reference.
      const auto current_noise = m_noise_tracker.back();
      const auto noise_stdev = nvbench::detail::statistics::standard_deviation(
        m_noise_tracker.cbegin(),
        m_noise_tracker.cend(),
        current_noise);
      const auto noise_rel_stdev = noise_stdev / current_noise;

      // If the rel stdev of the last N cuda noise measurements is less than
      // 5%, consider the result stable.
      const auto noise_threshold = 0.05;
      if (noise_rel_stdev < noise_threshold)
      {
        return true;
      }
    }
  }

  // Check for timeouts:
  m_walltime_timer.stop();
  if (m_walltime_timer.get_duration() > m_timeout)
  {
    m_max_time_exceeded = true;
    return true;
  }

  return false;
}

void measure_cold_base::run_trials_epilogue()
{
  // Only need to compute this at the end, not per iteration.
  const auto cpu_mean = m_total_cuda_time /
                        static_cast<nvbench::float64_t>(m_total_samples);
  const auto cpu_stdev =
    nvbench::detail::statistics::standard_deviation(m_cpu_times.cbegin(),
                                                    m_cpu_times.cend(),
                                                    cpu_mean);
  m_cpu_noise = cpu_stdev / cpu_mean;

  m_walltime_timer.stop();
}

void measure_cold_base::generate_summaries()
{
  const auto d_samples = static_cast<double>(m_total_samples);
  {
    auto &summ = m_state.add_summary("Number of Samples (Cold)");
    summ.set_string("hint", "sample_size");
    summ.set_string("short_name", "Samples");
    summ.set_string("description",
                    "Number of kernel executions in cold time measurements.");
    summ.set_int64("value", m_total_samples);
  }

  const auto avg_cpu_time = m_total_cpu_time / d_samples;
  {
    auto &summ = m_state.add_summary("Average CPU Time (Cold)");
    summ.set_string("hint", "duration");
    summ.set_string("short_name", "CPU Time");
    summ.set_string("description",
                    "Average isolated kernel execution time observed "
                    "from host.");
    summ.set_float64("value", avg_cpu_time);
  }

  {
    auto &summ = m_state.add_summary("CPU Relative Standard Deviation (Cold)");
    summ.set_string("hint", "percentage");
    summ.set_string("short_name", "Noise");
    summ.set_string("description",
                    "Relative standard deviation of the cold CPU execution "
                    "time measurements.");
    summ.set_float64("value", m_cpu_noise);
  }

  const auto avg_cuda_time = m_total_cuda_time / d_samples;
  {
    auto &summ = m_state.add_summary("Average GPU Time (Cold)");
    summ.set_string("hint", "duration");
    summ.set_string("short_name", "GPU Time");
    summ.set_string("description",
                    "Average isolated kernel execution time as measured "
                    "by CUDA events.");
    summ.set_float64("value", avg_cuda_time);
  }

  {
    auto &summ = m_state.add_summary("GPU Relative Standard Deviation (Cold)");
    summ.set_string("hint", "percentage");
    summ.set_string("short_name", "Noise");
    summ.set_string("description",
                    "Relative standard deviation of the cold GPU execution "
                    "time measurements.");
    summ.set_float64("value",
                     m_noise_tracker.empty()
                       ? std::numeric_limits<nvbench::float64_t>::infinity()
                       : m_noise_tracker.back());
  }

  if (const auto items = m_state.get_element_count(); items != 0)
  {
    auto &summ = m_state.add_summary("Element Throughput");
    summ.set_string("hint", "item_rate");
    summ.set_string("short_name", "Elem/s");
    summ.set_string("description",
                    "Number of input elements handled per second.");
    summ.set_float64("value", static_cast<double>(items) / avg_cuda_time);
  }

  if (const auto bytes = m_state.get_global_memory_rw_bytes(); bytes != 0)
  {
    const auto avg_used_gmem_bw = static_cast<double>(bytes) / avg_cuda_time;
    {
      auto &summ = m_state.add_summary("Average Global Memory Throughput");
      summ.set_string("hint", "byte_rate");
      summ.set_string("short_name", "GlobalMem BW");
      summ.set_string("description",
                      "Number of bytes read/written per second to the CUDA "
                      "device's global memory.");
      summ.set_float64("value", avg_used_gmem_bw);
    }

    {
      const auto peak_gmem_bw = static_cast<double>(
        m_state.get_device()->get_global_memory_bus_bandwidth());

      auto &summ = m_state.add_summary("Percent Peak Global Memory Throughput");
      summ.set_string("hint", "percentage");
      summ.set_string("short_name", "BWPeak");
      summ.set_string("description",
                      "Global device memory throughput as a percentage of the "
                      "device's peak bandwidth.");
      summ.set_float64("value", avg_used_gmem_bw / peak_gmem_bw);
    }
  }

  // Log if a printer exists:
  if (auto printer_opt_ref = m_state.get_benchmark().get_printer();
      printer_opt_ref.has_value())
  {
    auto &printer = printer_opt_ref.value().get();

    if (m_max_time_exceeded)
    {
      const auto timeout = m_walltime_timer.get_duration();

      if (!m_noise_tracker.empty() && m_noise_tracker.back() > m_max_noise)
      {
        printer.log(nvbench::log_level::warn,
                    fmt::format("Current measurement timed out ({:0.2f}s) "
                                "while over noise threshold ({:0.2f}% > "
                                "{:0.2f}%)",
                                timeout,
                                m_noise_tracker.back() * 100,
                                m_max_noise * 100));
      }
      if (m_total_samples < m_min_samples)
      {
        printer.log(nvbench::log_level::warn,
                    fmt::format("Current measurement timed out ({:0.2f}s) "
                                "before accumulating min_samples ({} < {})",
                                timeout,
                                m_total_samples,
                                m_min_samples));
      }
      if (m_total_cuda_time < m_min_time)
      {
        printer.log(nvbench::log_level::warn,
                    fmt::format("Current measurement timed out ({:0.2f}s) "
                                "before accumulating min_time ({:0.2f}s < "
                                "{:0.2f}s)",
                                timeout,
                                m_total_cuda_time,
                                m_min_time));
      }
    }

    // Log to stdout:
    printer.log(nvbench::log_level::pass,
                fmt::format("Cold: {:0.6f}ms GPU, {:0.6f}ms CPU, {:0.2f}s "
                            "total GPU, {}x",
                            avg_cuda_time * 1e3,
                            avg_cpu_time * 1e3,
                            m_total_cuda_time,
                            m_total_samples));
  }
}

void measure_cold_base::check_skip_time(nvbench::float64_t warmup_time)
{
  if (m_skip_time > 0. && warmup_time < m_skip_time)
  {
    auto reason = fmt::format("Warmup time did not meet skip_time limit: "
                              "{:0.3f}us < {:0.3f}us.",
                              warmup_time * 1e6,
                              m_skip_time * 1e6);

    m_state.skip(reason);
    NVBENCH_THROW(std::runtime_error, "{}", std::move(reason));
  }
}

void measure_cold_base::block_stream()
{
  m_blocker.block(m_launch.get_stream(), m_state.get_blocking_kernel_timeout());
}

} // namespace nvbench::detail
