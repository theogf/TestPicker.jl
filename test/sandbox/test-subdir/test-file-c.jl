using Test

@testset "First level" begin
    a = 2
    f(2)
    @testset "Second level" begin
        @test c == 3
        d = 4
    end
end

x = 5

@testset "First level - B" begin
    @test w == 1
end
