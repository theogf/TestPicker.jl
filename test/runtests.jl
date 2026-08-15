using SafeTestsets
using TestPicker

# A progress bar has no useful audience in the test suite's own output, and would just
# contend with `Test.jl`'s and `@safetestset`'s own printing.
TestPicker.TEST_PROGRESS_ENABLED[] = false

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
@safetestset "results_viewer" begin
    include("results_viewer.jl")
end
