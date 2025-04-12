using TestPicker
using Test
using TestPicker: create_repl_test_mode, identify_query
using TestPicker: TestFileQuery, LatestEval, TestsetQuery, UnmatchedQuery
using REPL: LineEdit

@testset "Building the REPL mode" begin
    repl = Base.active_repl
    test_mode = create_repl_test_mode(repl, repl.interface.modes[1])
    @test test_mode isa LineEdit.Prompt
    @test test_mode.prompt() == "test> "
    @test test_mode.on_done isa Function
end

@testset "Identify query" begin
    @test identify_query("") == (TestFileQuery, ("", ""))
    TestPicker.LATEST_EVAL[] = nothing
    @test identify_query("-") == (UnmatchedQuery, ())
    @test_logs (:error, "No test evaluated yet (reset with every session).") identify_query(
        "-"
    )
    TestPicker.LATEST_EVAL[] = TestPicker.TestInfo[]
    @test identify_query("-") == (LatestEval, TestPicker.LATEST_EVAL[])
    @test identify_query(":") == (TestsetQuery, ("", ""))
    @test identify_query("foo") == (TestFileQuery, ("foo", ""))
    @test identify_query("foo:a") == (TestsetQuery, ("foo", "a"))
    @test identify_query(":a") == (TestsetQuery, ("", "a"))
end
