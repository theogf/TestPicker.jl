using Test
using TestPicker
using TestPicker: TestPickerTestSet
using JSON

@testset "truncate_backtrace" begin
    fake_bt = """
Stacktrace:
 [1] user_func()
    @ UserModule /home/user/project/src/foo.jl:10
 [2] another_user_func()
    @ UserModule /home/user/project/src/bar.jl:20
 [3] include(mod::Module, _path::String)
    @ Base ./Base.jl:495
 [4] include(x::String)
    @ Main.var"##TestPicker#226" ./none:0
 [5] run_testfile(file::String)
    @ TestPicker /home/theo/.julia/dev/TestPicker/src/testfile.jl:205"""

    result = TestPicker.truncate_backtrace(fake_bt)

    @test contains(result, "user_func")
    @test contains(result, "another_user_func")
    @test !contains(result, "include(mod::Module")
    @test !contains(result, "run_testfile")
    @test contains(result, "Stacktrace:")
end

@testset "truncate_backtrace - top-level scope in TestPicker src" begin
    fake_bt = """
Stacktrace:
 [1] user_func()
    @ UserModule /home/user/project/src/foo.jl:10
 [2] another_user_func()
    @ UserModule /home/user/project/src/bar.jl:20
 [3] top-level scope
    @ ~/.julia/dev/TestPicker/src/testblock.jl:229
 [4] eval_in_module(::TestPicker.EvalTest)
    @ TestPicker ~/.julia/dev/TestPicker/src/eval.jl:112"""

    result = TestPicker.truncate_backtrace(fake_bt)

    @test contains(result, "user_func")
    @test contains(result, "another_user_func")
    @test !contains(result, "top-level scope")
    @test !contains(result, "eval_in_module")
end

@testset "truncate_backtrace - top-level scope in TestPicker src (Windows path)" begin
    fake_bt = """
Stacktrace:
 [1] user_func()
    @ UserModule /home/user/project/src/foo.jl:10
 [2] another_user_func()
    @ UserModule /home/user/project/src/bar.jl:20
 [3] top-level scope
    @ C:\\Users\\user\\.julia\\dev\\TestPicker\\src\\testblock.jl:229
 [4] eval_in_module(::TestPicker.EvalTest)
    @ TestPicker C:\\Users\\user\\.julia\\dev\\TestPicker\\src\\eval.jl:112"""

    result = TestPicker.truncate_backtrace(fake_bt)

    @test contains(result, "user_func")
    @test contains(result, "another_user_func")
    @test !contains(result, "top-level scope")
    @test !contains(result, "eval_in_module")
end

@testset "truncate_backtrace - no include boundary" begin
    fake_bt = """
Stacktrace:
 [1] foo()
    @ Bar /some/file.jl:1
 [2] baz()
    @ Bar /some/other.jl:2"""

    result = TestPicker.truncate_backtrace(fake_bt)
    # No truncation point found, returns cleaned string unchanged
    @test contains(result, "foo")
    @test contains(result, "baz")
end

@testset "truncate_backtrace - ANSI codes stripped" begin
    ansi_reset = "\e[0m"
    ansi_blue = "\e[34m"
    fake_bt = """
$(ansi_blue)Stacktrace:$(ansi_reset)
 [1] $(ansi_blue)user_func$(ansi_reset)()
    @ UserModule /home/user/project/src/foo.jl:10
 [2] include(mod::Module, _path::String)
    @ Base ./Base.jl:495"""

    result = TestPicker.truncate_backtrace(fake_bt)
    @test contains(result, "user_func")
    @test !contains(result, "\e[")
end

@testset "truncate_backtrace - no stack frames" begin
    fake_bt = "Some error with no stack"
    result = TestPicker.truncate_backtrace(fake_bt)
    @test result == fake_bt
end

@testset "group_frames" begin
    frames = TestPicker.group_frames([
        " [1] foo()", "   @ Bar /some/file.jl:1", " [2] baz()", "   @ Bar /some/other.jl:2"
    ])
    @test length(frames) == 2
    @test frames[1] == [" [1] foo()", "   @ Bar /some/file.jl:1"]
    @test frames[2] == [" [2] baz()", "   @ Bar /some/other.jl:2"]

    # Extra lines (e.g. exception chains) are attached to the frame they follow.
    frames = TestPicker.group_frames([
        " [1] foo()", "   @ Bar /some/file.jl:1", "caused by: MethodError"
    ])
    @test length(frames) == 1
    @test last(frames[1]) == "caused by: MethodError"

    # Lines before the first frame are kept in a group of their own.
    frames = TestPicker.group_frames(["nested task error: boom", " [1] foo()"])
    @test length(frames) == 2
    @test frames[1] == ["nested task error: boom"]
end

@testset "visualize_stacktrace without any frame" begin
    # Nothing to show, and no terminal/editor is needed to figure that out.
    @test TestPicker.visualize_stacktrace("ERROR: some error without stacktrace") == false
end

"""
Real `Test` results, as they come out of a run, to build entries from.

The testset has to be the root one for `TestPickerTestSet` to throw rather than report to a
parent, and `Test` keeps its testset stack in task local storage, so a fresh task gives us
that whatever testset this file itself runs under.
"""
function failing_results()
    printing = Test.TESTSET_PRINT_ENABLE[]
    Test.TESTSET_PRINT_ENABLE[] = false
    try
        return fetch(
            @async try
                @testset TestPickerTestSet "root" begin
                    @testset "inner" begin
                        @test 1 == 2
                        @test false
                        @test sqrt(-1) == 1
                    end
                    sqrt(-1)
                end
                error("the testset was expected to fail")
            catch e
                e isa TestPicker.TestPickerTestSetException ? e.results : rethrow()
            end
        )
    finally
        Test.TESTSET_PRINT_ENABLE[] = printing
    end
end

@testset "result_entry" begin
    results = failing_results()
    info = TestPicker.TestInfo("sandbox.jl", "block", 1)
    entries = [
        TestPicker.result_entry(r.result, info, r.testset_path, r.trace) for r in results
    ]
    @test length(entries) == 4

    # A failure has no stacktrace to show, and its preview stays a `String` even when
    # `Test.Fail.data` is `nothing`.
    fails = filter(e -> isnothing(e.trace), entries)
    @test length(fails) == 2
    @test all(e -> e.preview isa String, fails)
    @test all(e -> contains(e.context, "inner"), fails)

    # An error inside a `@test` only leaves the printed text behind, one outside of it
    # keeps the real frames, which carry the function names the text does not have.
    errors = filter(e -> !isnothing(e.trace), entries)
    @test length(errors) == 2
    from_text, from_backtrace = errors
    @test !isempty(from_text.trace.frames)
    @test all(!isnothing(f.file) && isfile(f.file) for f in from_text.trace.frames)
    @test !isempty(from_backtrace.trace.frames)
    @test first(from_backtrace.trace.frames).func == "throw_complex_domainerror"
    # TestPicker's own frames are cut from what it captured itself.
    @test !any(TestPicker.is_testpicker_frame(f) for f in from_backtrace.trace.frames)
end

@testset "results file round trip" begin
    results = failing_results()
    info = TestPicker.TestInfo("sandbox.jl", "block", 1)
    entries = [
        TestPicker.result_entry(r.result, info, r.testset_path, r.trace) for r in results
    ]
    path = joinpath(mktempdir(), "results.jsonl")
    TestPicker.write_results(path, entries)
    # A second run appends to the first one's results.
    TestPicker.write_results(path, entries)
    back = [
        JSON.parse(line, TestPicker.TestResultEntry) for
        line in eachline(path) if !isempty(line)
    ]
    @test length(back) == 2 * length(entries)
    @test [e.list_view for e in back[1:length(entries)]] == [e.list_view for e in entries]
    @test isnothing(back[1].trace) == isnothing(entries[1].trace)
    traced = findfirst(e -> !isnothing(e.trace), back)
    @test back[traced].trace.frames == entries[traced].trace.frames
end
