using Test
using Pkg: PackageSpec
using TestPicker: TestPicker, eval_in_module, current_pkg, EvalTest, TestInfo

@testset "Test eval in module" begin
    path = pkgdir(TestPicker)
    pkg_spec = PackageSpec(; name="TestPicker", path)
    @test isnothing(
        eval_in_module(EvalTest(:(sin(3)), TestInfo("eval.jl", "", 0), pkg_spec))
    )
    # Errors don't disturb the env
    @test_throws ErrorException eval_in_module(
        EvalTest(:(error("🤯")), TestInfo("eval.jl", "error", 2), pkg_spec)
    )
    @test isnothing(
        eval_in_module(
            EvalTest(:(@testset "foo" begin end), TestInfo("eval.jl", "foo", 10), pkg_spec)
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
            failing_call =
                () -> eval_in_module(
                    EvalTest(
                        :(@testset "failing" begin
                            @test false
                        end),
                        TestInfo("eval.jl", "failing", 20),
                        pkg_spec,
                    ),
                )
            if isdefined(Test, :CURRENT_TESTSET)
                Base.ScopedValues.with(
                    Test.CURRENT_TESTSET => Test.FallbackTestSet(), Test.TESTSET_DEPTH => 0
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

    # When wrapped in a `TestPickerTestSet` (as `run_testfile`/`testblock_list` do),
    # each failure keeps the `@testset` nesting path it occurred under.
    nested_result = fetch(
        Threads.@spawn begin
            failing_nested_call =
                () -> eval_in_module(
                    EvalTest(
                        :(@testset TestPickerTestSet "root" begin
                            @testset "inner" begin
                                @test false
                            end
                        end),
                        TestInfo("eval.jl", "nested", 30),
                        pkg_spec,
                    ),
                )
            if isdefined(Test, :CURRENT_TESTSET)
                Base.ScopedValues.with(
                    Test.CURRENT_TESTSET => Test.FallbackTestSet(), Test.TESTSET_DEPTH => 0
                ) do
                    failing_nested_call()
                end
            else
                failing_nested_call()
            end
        end
    )
    @test nested_result isa TestPicker.TestPickerTestSetException
    @test nested_result.fail == 1
    @test only(nested_result.results).testset_path == ["inner"]
end

# The cached-testenv branch used to set `ENV["JULIA_DEBUG"] = "loading"` without ever
# restoring it, leaking debug logging into the session from the second run on.
@testset "eval_in_module leaves JULIA_DEBUG alone" begin
    pkg_spec = PackageSpec(; name="TestPicker", path=pkgdir(TestPicker))
    # Twice, so that the second run goes through the cached test environment.
    function run_twice()
        for _ in 1:2
            eval_in_module(EvalTest(:(sin(3)), TestInfo("eval.jl", "", 0), pkg_spec))
        end
    end

    withenv("JULIA_DEBUG" => nothing) do
        run_twice()
        @test !haskey(ENV, "JULIA_DEBUG")
    end

    withenv("JULIA_DEBUG" => "Main") do
        run_twice()
        @test ENV["JULIA_DEBUG"] == "Main"
    end
end
