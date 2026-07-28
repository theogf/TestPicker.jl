using Test

@testset "First level" begin
    a = 2
    @testset "Second level" begin
        @test c == 3
        f(2)
        d = 4
    end
end

x = 5

@testset "First level - B" begin
    a = 1
    b = 2
    @test a == b
    @test w == 1
end
