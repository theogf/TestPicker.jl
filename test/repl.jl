using TestPicker
using Test
using TestPicker: create_repl_test_mode, identify_query
using TestPicker: TestFileQuery, LatestEval, TestsetQuery, UnmatchedQuery
using REPL: REPL, BasicREPL, LineEdit, Terminals, LineEditREPL, run_repl

# From Pkg.jl/REPLExt
struct FakeTerminal <: Terminals.UnixTerminal
    in_stream::IOBuffer
    out_stream::IOBuffer
    err_stream::IOBuffer
    hascolor::Bool
    raw::Bool
    FakeTerminal() = new(IOBuffer(), IOBuffer(), IOBuffer(), false, true)
end
REPL.raw!(::FakeTerminal, raw::Bool) = raw
@testset "Building the REPL mode" begin
    if Sys.isunix()
        tty = FakeTerminal()
        repl = LineEditREPL(tty, true)
        run_repl(repl)
        test_mode = create_repl_test_mode(repl, repl.interface.modes[1])
        @test test_mode isa LineEdit.Prompt
        @test test_mode.prompt() == "test> "
        @test test_mode.on_done isa Function
    end
end

@testset "Identify query" begin
    @test identify_query("") == (TestFileQuery, ("", ""))
    TestPicker.LATEST_EVAL[] = nothing
    @test identify_query("-") == (UnmatchedQuery, ())
    @test_logs (:error, "No test evaluated yet (reset with every session).") identify_query(
        "-"
    )
    TestPicker.LATEST_EVAL[] = TestPicker.EvalTest[]
    @test identify_query("-") == (LatestEval, TestPicker.LATEST_EVAL[])
    @test identify_query(":") == (TestsetQuery, ("", ""))
    @test identify_query("foo") == (TestFileQuery, ("foo", ""))
    @test identify_query("foo:a") == (TestsetQuery, ("foo", "a"))
    @test identify_query(":a") == (TestsetQuery, ("", "a"))
end
