using Test
using JuliaSyntax
using TestPicker

@testset "Testset node detection" begin
    s = """
    @testset "asda" begin
      @test true
    end
    """

    s2 = """
    using Pkg
    """

    root = parseall(SyntaxNode, s)
    @test TestPicker.is_testset(only(JuliaSyntax.children(root)))
    root = parseall(SyntaxNode, s2)
    @test !TestPicker.is_testset(only(JuliaSyntax.children(root)))
end
