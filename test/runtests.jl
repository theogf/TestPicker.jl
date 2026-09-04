using SafeTestsets

@safetestset "eval" begin
    include("eval.jl")
end
@safetestset "testfile" begin
    include("testfile.jl")
end
@safetestset "workspace" begin
    include("workspace.jl")
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
@safetestset "trace" begin
    include("trace.jl")
end
@safetestset "results_viewer" begin
    include("results_viewer.jl")
end
@safetestset "error_inspector" begin
    include("error_inspector.jl")
end
