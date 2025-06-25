using Test
using Pkg.Types: PackageSpec
using TestPicker
using TestPicker: EvalTest, get_test_files, run_test_file

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
            "sandbox/test-testitem.jl",
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

@testset "Running a file containing @testitem tests" begin
    path = pkgdir(TestPicker)
    pkg_spec = PackageSpec(; name="TestPicker", path)
    # We test that this correctly executes without errors mostly here
    @test run_test_file(joinpath(@__DIR__, "sandbox/test-testitem.jl"), pkg_spec) === nothing
end