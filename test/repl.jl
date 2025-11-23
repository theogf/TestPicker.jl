using TestPicker
using Test
using TestPicker: create_repl_test_mode, identify_query, print_test_docs, HELP_TEXT
using TestPicker: TestFileQuery, LatestEval, TestsetQuery, UnmatchedQuery, TestModeDocs
using REPL: REPL, BasicREPL, LineEdit, Terminals, LineEditREPL, run_repl
using Markdown

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
    @test identify_query("?") == (TestModeDocs, ())
end

@testset "Help documentation" begin
    @test HELP_TEXT isa Markdown.MD

    # Test that help text contains key sections
    help_str = string(HELP_TEXT)
    @test contains(help_str, "TestPicker Test Mode")
    @test contains(help_str, "Test File Selection")
    @test contains(help_str, "Test Block Selection")
    @test contains(help_str, "Special Commands")
    @test contains(help_str, "Fuzzy Selection Mode")

    # Test that it mentions key commands
    @test contains(help_str, "test> -")
    @test contains(help_str, "test> @")
    @test contains(help_str, "test> ?")

    # Test that print_test_docs doesn't error
    io = IOBuffer()
    redirect_stdout(io) do
        print_test_docs()
    end
    output = String(take!(io))
    @test !isempty(output)
    @test contains(output, "TestPicker Test Mode")
end
