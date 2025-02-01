using SafeTestsets

@safetestset "eval" begin
    include("eval.jl")
end
@safetestset "testfile" begin
    include("testfile.jl")
end
@safetestset "testblock" begin
    include("testblock.jl")
end
@safetestset "repl" begin
    include("repl.jl")
end

@testset "Second test" begin
    @testset "Inner test" begin end
end
