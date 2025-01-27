using TestPicker
using Test
using TerminalRegressionTests

@testset "TestPicker.jl" begin
    mktemp() do file, _
        TerminalRegressionTests.automated_test(file, ["! testa", ""]) do term
        end
    end
end

@testset "Second test" begin
    @testset "Inner test" begin
    end
end
