# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "quickjs"
require "minitest/autorun"
require 'etc'

module QuickjsTestHelpers
  # Asserts the block runs in parallel across Ruby threads, by comparing
  # wall-clock for the same total amount of work done serially in one thread
  # vs split across two threads. If the work releases the GVL during its hot
  # section, the 2-thread run finishes in ~half the wall clock; if it holds
  # the GVL, both runs take roughly the same time. The 2/3 threshold cleanly
  # distinguishes the two while leaving headroom for thread scheduling jitter.
  #
  # The block receives an iteration count and is expected to do that many
  # units of the operation under test (e.g. eval_code calls, VM constructions).
  # Each thread should create its own VM internally, because QuickJS records
  # the runtime's stack base at construction time — using a VM from a thread
  # other than its creator trips a (false) stack-overflow guard.
  def assert_run_in_parallel(trials: 5, total_iterations: 8, &workload)
    skip 'requires 2+ cores' if Etc.nprocessors < 2

    measure = ->(&block) {
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      block.call
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    }

    workload.call(1) # warmup: load JIT / page in caches before timing

    single = trials.times.map {
      measure.call { workload.call(total_iterations) }
    }.min

    parallel = trials.times.map {
      measure.call {
        threads = Array.new(2) {
          Thread.new { workload.call(total_iterations / 2) }
        }
        threads.each(&:join)
      }
    }.min

    assert_operator parallel, :<=, single * 2.0 / 3,
      "parallel wall clock #{(parallel * 1000).round(1)}ms not ≤ 2/3 × single #{(single * 1000).round(1)}ms — work may not be releasing the GVL"
  end
end

Minitest::Spec.include(QuickjsTestHelpers)
