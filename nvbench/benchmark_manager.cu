/*
 *  Copyright 2020 NVIDIA Corporation
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

#include <nvbench/benchmark_manager.cuh>

#include <fmt/format.h>

#include <algorithm>
#include <stdexcept>

namespace nvbench
{

benchmark_manager &benchmark_manager::get()
{ // Karen's function:
  static benchmark_manager the_manager;
  return the_manager;
}

benchmark_base &benchmark_manager::add(std::unique_ptr<benchmark_base> bench)
{
  m_benchmarks.push_back(std::move(bench));
  return *m_benchmarks.back();
}

benchmark_manager::benchmark_vector benchmark_manager::clone_benchmarks() const
{
  benchmark_vector result(m_benchmarks.size());
  std::transform(m_benchmarks.cbegin(),
                 m_benchmarks.cend(),
                 result.begin(),
                 [](const auto &bench) { return bench->clone(); });
  return result;
}

const benchmark_base &
benchmark_manager::get_benchmark(const std::string &name) const
{
  auto iter = std::find_if(m_benchmarks.cbegin(),
                           m_benchmarks.cend(),
                           [&name](const auto &bench_ptr) {
                             return bench_ptr->get_name() == name;
                           });
  if (iter == m_benchmarks.cend())
  {
    throw std::out_of_range(
      fmt::format("{}:{}: No benchmark named '{}'.", name));
  }

  return **iter;
}

} // namespace nvbench
