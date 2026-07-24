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
    # On Julia >= 1.13, Test.jl tracks the current testset via `ScopedValue`s, which
    # (unlike the old task_local_storage-based state) *are* inherited by spawned tasks,
    # so a plain `Threads.@spawn` no longer detaches from the enclosing testset. Reset
    # the scope explicitly in that case so the inner `@testset` is still treated as
    # top-level.
    result = fetch(
        Threads.@spawn begin
            failing_call = () -> eval_in_module(
                EvalTest(
                    :(@testset "failing" begin
                        @test false
                    end),
                    TestInfo("eval.jl", "failing", 20),
                ),
                pkg_spec,
            )
            if isdefined(Test, :CURRENT_TESTSET)
                Base.ScopedValues.with(
                    Test.CURRENT_TESTSET => Test.FallbackTestSet(),
                    Test.TESTSET_DEPTH => 0,
                ) do
                    failing_call()
                end
            else
                failing_call()
            end
        end
    )
    @test result isa Test.TestSetException
    @test result.fail == 1
end
