using Test
using TestPicker: eval_in_module

@testset "Test eval in module" begin
    current_proj = Base.current_project()
    @test isnothing(eval_in_module(:(sin(3)), "TestPicker"))
    @test Base.current_project() == current_proj
    # Errors don't disturb the env
    @test_throws ErrorException eval_in_module(:(error("🤯")), "TestPicker")
    @test Base.current_project() == current_proj
    @test isnothing(eval_in_module(:(@testset "foo" begin end), "TestPicker"))
end
