using Test
using Pkg
using Pkg.Types: PackageSpec
using TestPicker
using TestPicker:
    EvalTest,
    EvalResult,
    TestFile,
    common_root,
    fzf_testfile,
    get_testfiles,
    run_testfile,
    select_testfiles

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

@testset "Get test files of several packages" begin
    path = pkgdir(TestPicker)
    pkg_spec = PackageSpec(; name="TestPicker", path)
    # A lone package needs no qualification, its file names are unambiguous already.
    files = get_testfiles([pkg_spec])
    @test files isa Vector{TestFile}
    @test all(file -> file.label == file.name, files)
    @test all(file -> file.root == joinpath(path, "test"), files)
    file = only(filter(file -> file.name == "sandbox/test-a.jl", files))
    @test abspath(file) == joinpath(path, "test", "sandbox", "test-a.jl")

    # As soon as several packages are in play, the label names the package.
    other = PackageSpec(; name="TestPicker", path)
    qualified = get_testfiles([pkg_spec, other])
    @test all(file -> file.label == joinpath("TestPicker", file.name), qualified)
    @test length(qualified) == 2 * length(files)
end

@testset "Common root of test files" begin
    pkg_spec = PackageSpec(; name="TestPicker", path=pkgdir(TestPicker))
    root = joinpath(pkgdir(TestPicker), "test")
    # A single test directory is its own common root.
    @test common_root([TestFile(pkg_spec, root, "runtests.jl")]) == root
    # Otherwise the deepest directory holding all of them, e.g. the workspace directory.
    other_root = joinpath(pkgdir(TestPicker), "docs", "test")
    @test common_root([
        TestFile(pkg_spec, root, "runtests.jl"),
        TestFile(pkg_spec, other_root, "runtests.jl"),
    ]) == pkgdir(TestPicker)
end

@testset "Running a given file" begin
    TestPicker.LATEST_EVAL[] = nothing
    path = pkgdir(TestPicker)
    pkg_spec = PackageSpec(; name="TestPicker", path)
    file = TestFile(pkg_spec, joinpath(path, "test"), "sandbox/test-a.jl")
    @test_logs (
        :info, "Executing test file sandbox/test-a.jl in the test environment of TestPicker"
    ) run_testfile(file)
    @test TestPicker.LATEST_EVAL[] isa Vector{EvalTest}
    evaltest = only(TestPicker.LATEST_EVAL[])
    @test evaltest.info.filename == "sandbox/test-a.jl"
    @test evaltest.pkg == pkg_spec
end

@testset "Non-interactive file selection" begin
    path = pkgdir(TestPicker)
    pkg_spec = PackageSpec(; name="TestPicker", path)

    # Test selecting files with a query that matches multiple files
    mode, files = select_testfiles("test-a", [pkg_spec]; interactive=false)
    @test mode == :file
    @test all(file -> file.root == joinpath(path, "test"), files)
    @test "sandbox/test-a.jl" in [file.name for file in files]

    # Test selecting files with a query that matches no files
    mode, files = select_testfiles("nonexistent-file-xyz", [pkg_spec]; interactive=false)
    @test mode == :file
    @test isempty(files)

    # Test selecting files with a broader query
    mode, files = select_testfiles("sandbox", [pkg_spec]; interactive=false)
    @test mode == :file
    @test length(files) >= 3  # At least test-a, test-b, and weird-name
    @test any(file -> startswith(file.name, "sandbox/"), files)
end

@testset "fzf_testfile return type" begin
    # `fzf_testfile` picks its packages from the active environment, which under
    # `Pkg.test` is the sandbox test environment rather than the package itself.
    Pkg.activate(pkgdir(TestPicker)) do
        # Test that fzf_testfile returns a vector when files match
        result = fzf_testfile("test-a"; interactive=false)
        @test result isa Vector
        @test all(r -> r isa EvalResult, result)

        # Test that fzf_testfile returns nothing when no files match
        result = fzf_testfile("nonexistent-xyz"; interactive=false)
        @test isnothing(result)
    end
end
