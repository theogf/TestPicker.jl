using Test
using Pkg: PackageSpec
using TestPicker: TestPicker, eval_in_module, current_pkg, TestInfo

@testset "Test eval in module" begin
    path = pkgdir(TestPicker)
    pkg_spec = PackageSpec(; name="TestPicker", path)
    @test isnothing(eval_in_module(TestInfo(:(sin(3)), "eval.jl", "", 0), pkg_spec))
    # Errors don't disturb the env
    @test_throws ErrorException eval_in_module(
        TestInfo(:(error("🤯")), "eval.jl", "error", 2), pkg_spec
    )
    @test isnothing(
        eval_in_module(TestInfo(:(@testset "foo" begin end), "eval.jl", "foo", 10), pkg_spec)
    )
end
