using Test

x = 2

@testset "Another name" begin
    @test true
end

@testset "Failing testset" begin
    @test false
end

w = "a"

@testset "Using global variables" begin
    @test x == 2
    @test w == "a"
end
