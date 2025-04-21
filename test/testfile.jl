using Test
using Pkg.Types: PackageSpec
using TestPicker
using TestPicker: TestInfo, get_test_files, run_test_file

@testset "Get test files" begin
    path = pkgdir(TestPicker)
    pkg_spec = PackageSpec(; name="TestPicker", path)
    root, test_files = get_test_files(pkg_spec)
    @test root == joinpath(path, "test")
    @test issetequal(
        filter(startswith("sandbox"), test_files),
        [
            "sandbox/test-a.jl",
            "sandbox/test-b.jl",
            "sandbox/test-subdir/test-file-c.jl",
            "sandbox/weird-name.jl",
        ],
    )
end

@testset "Running a given file" begin
    TestPicker.LATEST_EVAL[] = nothing
    path = pkgdir(TestPicker)
    pkg_spec = PackageSpec(; name="TestPicker", path)
    @test_logs (:info, "Executing test file sandbox/test-a.jl") run_test_file(
        "sandbox/test-a.jl", pkg_spec
    )
    @test TestPicker.LATEST_EVAL[] isa Vector{EvalTest}
    evaltest = only(TestPicker.LATEST_EVAL[])
    @test evaltest.info.filename == "sandbox/test-a.jl"
end
