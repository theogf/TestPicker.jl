using SafeTestsets

@safetestset "eval" begin
    include("eval.jl")
end
@safetestset "testfile" begin
    include("testfile.jl")
end
@safetestset "testblockinterface" begin
    include("testblockinterface.jl")
end
@safetestset "testblock" begin
    include("testblock.jl")
end
@safetestset "repl" begin
    include("repl.jl")
end
@safetestset "fzf_interactive" begin
    include("fzf_interactive.jl")
end
