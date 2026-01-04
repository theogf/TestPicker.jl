using Test
using Pkg.Types: PackageSpec
using TestPicker
using TestPicker: EvalTest, get_testfiles, run_testfile, select_testfiles

@testset "Get test files" begin
    path = pkgdir(TestPicker)
    pkg_spec = PackageSpec(; name="TestPicker", path)
    root, testfiles = get_testfiles(pkg_spec)
    @test root == joinpath(path, "test")
    @test issetequal(
        filter(startswith("sandbox"), testfiles),
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
    @test_logs (:info, "Executing test file sandbox/test-a.jl") run_testfile(
        "sandbox/test-a.jl", pkg_spec
    )
    @test TestPicker.LATEST_EVAL[] isa Vector{EvalTest}
    evaltest = only(TestPicker.LATEST_EVAL[])
    @test evaltest.info.filename == "sandbox/test-a.jl"
end

@testset "Non-interactive file selection" begin
    path = pkgdir(TestPicker)
    pkg_spec = PackageSpec(; name="TestPicker", path)

    # Test selecting files with a query that matches multiple files
    mode, root, files = select_testfiles("test-a", pkg_spec; interactive=false)
    @test mode == :file
    @test root == joinpath(path, "test")
    @test "sandbox/test-a.jl" in files

    # Test selecting files with a query that matches no files
    mode, root, files = select_testfiles(
        "nonexistent-file-xyz", pkg_spec; interactive=false
    )
    @test mode == :file
    @test root == joinpath(path, "test")
    @test isempty(files)

    # Test selecting files with a broader query
    mode, root, files = select_testfiles("sandbox", pkg_spec; interactive=false)
    @test mode == :file
    @test root == joinpath(path, "test")
    @test length(files) >= 3  # At least test-a, test-b, and weird-name
    @test any(startswith("sandbox/"), files)
end
