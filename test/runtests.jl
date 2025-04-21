using SafeTestsets

@safetestset "eval" begin
    include("eval.jl")
end
@safetestset "testfile" begin
    include("testfile.jl")
end
@safetestset "testset" begin
    include("testset.jl")
end
@safetestset "repl" begin
    include("repl.jl")
end
