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
end

function TestPickerTestSet(desc::AbstractString)
    parent = Test.get_testset()
    failfast = parent isa TestPickerTestSet ? parent.dts.failfast : false
    return TestPickerTestSet(Test.DefaultTestSet(desc; failfast))
end

"""
    CURRENT_PROGRESS

`ProgressMeter.Progress` bar for the current [`eval_in_module`](@ref) run, or `nothing`
between runs.

Set up before each run (sized from [`EvalTest.expected_tests`](@ref)) and advanced from
[`Test.record`](@ref) as leaf test results come in.
"""
const CURRENT_PROGRESS = Ref{Union{Nothing,ProgressMeter.Progress}}(nothing)

"""
    TEST_PROGRESS_ENABLED

Whether [`eval_in_module`](@ref) shows a live progress bar while tests run. `true` by
default; set to `false` (e.g. `TestPicker.TEST_PROGRESS_ENABLED[] = false`) to opt out.
TestPicker's own test suite does this, since a progress bar has no useful audience there
and would just add noise (and, under `SafeTestsets`, contend with `Test.jl`'s own output).
"""
const TEST_PROGRESS_ENABLED = Ref(true)

"""
    ProgressCounts

Live tally of leaf test results (`pass`/`fail`/`error`/`broken`) for the current
[`eval_in_module`](@ref) run, used to color [`CURRENT_PROGRESS`](@ref) red once a failure
or error shows up.

Deliberately not displayed as `ProgressMeter`'s multi-line `showvalues`: that panel
redraws by moving the cursor with ANSI escapes between updates, and `Test.jl` prints a
failed/errored result's details via its own uncoordinated `print` call the moment it
happens — if that lands mid-redraw, the two writes interleave at the character level.
A single `\\r`-redrawn line doesn't have that failure mode: at worst it gets overwritten.
"""
mutable struct ProgressCounts
    pass::Int
    fail::Int
    error::Int
    broken::Int
end
ProgressCounts() = ProgressCounts(0, 0, 0, 0)

const CURRENT_PROGRESS_COUNTS = Ref(ProgressCounts())

progress_color((; fail, error)::ProgressCounts) = (fail + error) > 0 ? :red : :green

"""
    finish_progress!()

Complete and clear [`CURRENT_PROGRESS`](@ref), if one is active; a no-op otherwise.

Called from [`Test.finish`](@ref) right before the results table prints, so the bar's own
completion line lands above it instead of after (`ProgressMeter` writes to `stderr` by
default, `Test.print_test_results` to `stdout`, so without this the two interleave
unpredictably on a terminal). Idempotent so the fallback call in
[`eval_in_module`](@ref)'s `finally` (for code that errors before any testset even
starts) doesn't reprint a completed bar.
"""
function finish_progress!()
    prog = CURRENT_PROGRESS[]
    isnothing(prog) && return nothing
    ProgressMeter.finish!(prog; color=progress_color(CURRENT_PROGRESS_COUNTS[]))
    CURRENT_PROGRESS[] = nothing
    return nothing
end

function Test.record(ts::TestPickerTestSet, t::Test.Result, args...; kwargs...)
    prog = CURRENT_PROGRESS[]
    if !isnothing(prog)
        counts = CURRENT_PROGRESS_COUNTS[]
        if t isa Test.Pass
            counts.pass += 1
        elseif t isa Test.Fail
            counts.fail += 1
        elseif t isa Test.Error
            counts.error += 1
        elseif t isa Test.Broken
            counts.broken += 1
        end
        # `expected_tests` is only a static prediction (e.g. a `@test` inside a runtime
        # loop is counted once no matter how many times it actually runs), so once the
        # counter catches up to `n`, keep growing it a step ahead of the counter instead
        # of letting them meet: ProgressMeter treats `counter == n` as "done" and prints
        # a newline-terminated completion line right then, and doing that more than once
        # (once per undercounted step) is what left the bar printing duplicate lines.
        # The real completion line is printed once, by `finish_progress!`.
        max_steps = prog.counter + 1 >= prog.n ? prog.counter + 2 : prog.n
        ProgressMeter.next!(prog; max_steps, color=progress_color(counts))
        # `Test.record` prints a `Fail`/`Error`'s details immediately, via its own `print`
        # call that assumes it's starting on a blank line. The bar's own line never ends
        # in a newline (so the next redraw can `\r` back over it), so without this the
        # failure message would run straight on from wherever the bar's cursor was left.
        # `\r\e[K` clears that line in place rather than `println`ing past it: a newline
        # would "commit" the bar's half-finished line to scrollback as a stray leftover,
        # instead of it just cleanly disappearing under the message that replaces it.
        if (t isa Union{Test.Fail,Test.Error}) && prog.enabled
            print(prog.output, "\r\e[K")
        end
    end
    return Test.record(ts.dts, t, args...; kwargs...)
end

function Test.record(ts::TestPickerTestSet, t::Test.AbstractTestSet, args...; kwargs...)
    Test.record(ts.dts, t, args...; kwargs...)
end

"""
    TestPickerResult

A single failed or errored test, together with the chain of `@testset` descriptions
(outermost to innermost) it occurred under, not counting TestPicker's own root testset.
"""
struct TestPickerResult
    testset_path::Vector{String}
    result::Union{Test.Fail,Test.Error}
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
function collect_results(ts::Test.DefaultTestSet, path::Vector{String}=String[])
    results = TestPickerResult[]
    for t in ts.results
        if t isa Test.DefaultTestSet
            append!(results, collect_results(t, [path; t.description]))
        elseif t isa Union{Test.Fail,Test.Error}
            push!(results, TestPickerResult(path, t))
        end
    end
    return results
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

    finish_progress!()
    print_results && Test.print_test_results(dts)

    if total != total_pass + total_broken
        throw(
            TestPickerTestSetException(
                total_pass, total_fail, total_error, total_broken, collect_results(dts)
            ),
        )
    end
    return ts
end
