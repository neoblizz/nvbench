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

#pragma once

#include <nvbench/cuda_call.cuh>

#include <cuda_runtime_api.h>

namespace nvbench
{

// RAII wrapper for a cudaStream_t.
struct cuda_stream
{
  cuda_stream() { NVBENCH_CUDA_CALL(cudaStreamCreate(&m_stream)); }
  ~cuda_stream() { NVBENCH_CUDA_CALL(cudaStreamDestroy(m_stream)); }

  // move-only
  cuda_stream(const cuda_stream &) = delete;
  cuda_stream(cuda_stream &&)      = default;
  cuda_stream &operator=(const cuda_stream &) = delete;
  cuda_stream &operator=(cuda_stream &&) = default;

  operator cudaStream_t() const { return m_stream; }

private:
  cudaStream_t m_stream;
};

} // namespace nvbench
