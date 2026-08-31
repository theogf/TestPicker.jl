"""
    TestPickerTestSet

Root `Test.AbstractTestSet` used by TestPicker to run tests instead of `Test.DefaultTestSet`.

Wraps a real `Test.DefaultTestSet` and forwards all recording to it, so nested `@testset`s
behave exactly as they would under a plain `DefaultTestSet`. The only difference shows up
when the outermost testset finishes with failures: instead of `Test.TestSetException`,
which flattens every failure into a flat list and discards which `@testset` it occurred in,
`finish` throws a [`TestPickerTestSetException`](@ref) that keeps the full `@testset`
nesting path for each failure.

Since `Test.@testset` reuses the parent testset's type for any nested `@testset` that
doesn't specify one explicitly, wrapping just the outermost call in
`@testset TestPickerTestSet ... end` is enough to make every testset in the run a
`TestPickerTestSet`, all the way down.
"""
struct TestPickerTestSet <: Test.AbstractTestSet
    dts::Test.DefaultTestSet
    traces::Vector{Pair{Test.Error,TraceError}}
end

function TestPickerTestSet(desc::AbstractString)
    parent = Test.get_testset()
    failfast = parent isa TestPickerTestSet ? parent.dts.failfast : false
    # Nested testsets share the root's captured traces: `finish` hands the wrapped
    # `DefaultTestSet` to the parent, so anything stored on a nested wrapper is lost.
    traces = parent isa TestPickerTestSet ? parent.traces : Pair{Test.Error,TraceError}[]
    return TestPickerTestSet(Test.DefaultTestSet(desc; failfast), traces)
end

function Test.record(ts::TestPickerTestSet, args...; kwargs...)
    Test.record(ts.dts, args...; kwargs...)
end

function Test.record(ts::TestPickerTestSet, res::Test.Error, args...; kwargs...)
    trace = captured_trace(res)
    isnothing(trace) || push!(ts.traces, res => trace)
    return Test.record(ts.dts, res, args...; kwargs...)
end

"""
Capture the stacktrace of an errored test from the real backtrace, when it is still
reachable.

`Test` stringifies the backtrace as it builds a `Test.Error`, so `record` never receives
the frames themselves. But for an error thrown *outside* of a `@test`, `record` is called
from within `Test`'s own `catch` block, which means the exception stack of the task is
still live and `Base.current_exceptions()` hands us the real frames. An error raised
inside a `@test` is already out of that `catch` by the time `record` runs, and only the
printed text remains, see [`trace_error`](@ref).
"""
function captured_trace(res::Test.Error)
    res.test_type === :nontest_error || return nothing
    stack = Base.current_exceptions()
    isempty(stack) && return nothing
    return drop_test_frames(truncate_trace(trace_error(stack)))
end

"""
    TestPickerResult

A single failed or errored test, together with the chain of `@testset` descriptions
(outermost to innermost) it occurred under, not counting TestPicker's own root testset,
and the stacktrace captured from the real backtrace when there was one to capture, see
[`captured_trace`](@ref).
"""
struct TestPickerResult
    testset_path::Vector{String}
    result::Union{Test.Fail,Test.Error}
    trace::Union{Nothing,TraceError}
end

"""
    TestPickerTestSetException

Thrown when a [`TestPickerTestSet`](@ref) finishes and not all tests passed.

Like `Test.TestSetException`, but `results` pairs each failure with the `@testset`
nesting path it occurred under instead of discarding it.
"""
struct TestPickerTestSetException <: Exception
    pass::Int
    fail::Int
    error::Int
    broken::Int
    results::Vector{TestPickerResult}
end

function Base.showerror(io::IO, ex::TestPickerTestSetException, bt; backtrace=true)
    print(io, "Some tests did not pass: ")
    print(io, ex.pass, " passed, ")
    print(io, ex.fail, " failed, ")
    print(io, ex.error, " errored, ")
    print(io, ex.broken, " broken.")
end

"Recursively collect failed/errored tests from a testset tree, tracking the `@testset` path to each."
function collect_results(
    ts::Test.DefaultTestSet,
    traces::Vector{Pair{Test.Error,TraceError}},
    path::Vector{String}=String[],
)
    results = TestPickerResult[]
    for t in ts.results
        if t isa Test.DefaultTestSet
            append!(results, collect_results(t, traces, [path; t.description]))
        elseif t isa Union{Test.Fail,Test.Error}
            push!(results, TestPickerResult(path, t, trace_of(traces, t)))
        end
    end
    return results
end

"The trace captured for a given result while it was recorded, if any."
function trace_of(traces::Vector{Pair{Test.Error,TraceError}}, result)
    idx = findfirst(((recorded, _),) -> recorded === result, traces)
    return isnothing(idx) ? nothing : last(traces[idx])
end

"""
`Test.get_test_counts` returns a positional tuple on Julia <= 1.11 and a
`Test.TestCounts` struct (with no `iterate` method) from Julia 1.12 onwards. Handle
both instead of destructuring positionally.

We also deliberately never set `dts.time_end` ourselves: on Julia 1.13+ that field is
`@atomic`, and writing it plainly (as opposed to `Test`'s own `@atomicswap`) throws.
Leaving it unset just means `Test.print_test_results` omits the duration, which every
supported version already handles gracefully (`DefaultTestSet`'s own nested testsets
skip printing entirely, so an unset `time_end` is not a state `Test.jl` special-cases).
"""
function total_counts(dts::Test.DefaultTestSet)
    tc = Test.get_test_counts(dts)
    if tc isa Tuple
        passes, fails, errors, broken, c_passes, c_fails, c_errors, c_broken, _ = tc
    else
        passes, fails, errors, broken = tc.passes, tc.fails, tc.errors, tc.broken
        c_passes, c_fails, c_errors, c_broken = tc.cumulative_passes,
        tc.cumulative_fails, tc.cumulative_errors,
        tc.cumulative_broken
    end
    return passes + c_passes, fails + c_fails, errors + c_errors, broken + c_broken
end

function Test.finish(ts::TestPickerTestSet; print_results::Bool=Test.TESTSET_PRINT_ENABLE[])
    (; dts) = ts
    # If we are a nested test set, attach ourselves to the parent like `DefaultTestSet` does,
    # and let the outermost testset do the aggregation/printing/throwing.
    if Test.get_testset_depth() != 0
        Test.record(Test.get_testset(), dts)
        return ts
    end

    total_pass, total_fail, total_error, total_broken = total_counts(dts)
    total = total_pass + total_fail + total_error + total_broken

    print_results && Test.print_test_results(dts)

    if total != total_pass + total_broken
        throw(
            TestPickerTestSetException(
                total_pass,
                total_fail,
                total_error,
                total_broken,
                collect_results(dts, ts.traces),
            ),
        )
    end
    return ts
end
