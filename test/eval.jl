using Test
using Pkg: PackageSpec
using TestPicker: TestPicker, eval_in_module, current_pkg, EvalTest, TestInfo

@testset "Test eval in module" begin
    path = pkgdir(TestPicker)
    pkg_spec = PackageSpec(; name="TestPicker", path)
    @test isnothing(
        eval_in_module(EvalTest(:(sin(3)), TestInfo("eval.jl", "", 0)), pkg_spec)
    )
    # Errors don't disturb the env
    @test_throws ErrorException eval_in_module(
        EvalTest(:(error("🤯")), TestInfo("eval.jl", "error", 2)), pkg_spec
    )
    @test isnothing(
        eval_in_module(
            EvalTest(:(@testset "foo" begin end), TestInfo("eval.jl", "foo", 10)), pkg_spec
        ),
    )
    # Failing tests return a TestSetException rather than throwing.
    # Run in a spawned task to avoid nesting inside the current testset context,
    # which mirrors how eval_in_module is used from the REPL.
    result = fetch(
        Threads.@spawn eval_in_module(
            EvalTest(
                :(@testset "failing" begin
                    @test false
                end),
                TestInfo("eval.jl", "failing", 20),
            ),
            pkg_spec,
        )
    )
    @test result isa Test.TestSetException
    @test result.fail == 1
end
