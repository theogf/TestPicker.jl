using Test
using Pkg: PackageSpec
using TestPicker: TestPicker, eval_in_module, current_pkg

@testset "Test eval in module" begin
    path = pkgdir(TestPicker)
    pkg_spec = PackageSpec(; name="TestPicker", path)
    @test isnothing(eval_in_module(:(sin(3)), pkg_spec))
    # Errors don't disturb the env
    @test_throws ErrorException eval_in_module(:(error("🤯")), pkg_spec)
    @test isnothing(eval_in_module(:(@testset "foo" begin end), pkg_spec))
end
