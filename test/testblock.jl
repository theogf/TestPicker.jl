using Test
using JuliaSyntax
using TestPicker
using TestPicker: TestsetInfo
using TestPicker: get_test_files, get_matching_files, build_file_testset_map, pick_testset

@testset "Testset node detection" begin
    s = """
    @testset "asda" begin
      @test true
    end
    """

    s2 = """
    using Pkg
    """

    root = parseall(SyntaxNode, s)
    @test TestPicker.is_testset(only(JuliaSyntax.children(root)))
    root = parseall(SyntaxNode, s2)
    @test !TestPicker.is_testset(only(JuliaSyntax.children(root)))
end
@testset "Matching files" begin
    matched_files = get_matching_files("foo", ["test-foo", "test-bar"])
    @test matched_files == ["test-foo"]
    matched_files = get_matching_files("foo", ["test-foo", "foto", "test-bar"])
    @test issetequal(matched_files, ["test-foo", "foto"])
    matched_files = get_matching_files("foo", ["bar"])
    @test isempty(matched_files)
end

@testset "Build file testsets map" begin
    root = joinpath(pkgdir(TestPicker), "test", "sandbox")
    file = "test-a.jl"
    full_map, tabled_keys = build_file_testset_map(root, [file])
    @test length(full_map) == length(tabled_keys)
    @test only(keys(full_map)) == TestsetInfo("\"I am a testset\"", file, 3, 5)
    test_data = only(values(full_map))
    @test test_data isa Pair{SyntaxNode,Vector{SyntaxNode}}
    string_version = string(Base.remove_linenums!(Expr(first(test_data))))
    stripped_lines = strip.(split(string_version, '\n'))
    @test first(stripped_lines) ==
        """#= $(joinpath(root, file)):3 =# @testset "I am a testset" begin"""
    @test stripped_lines[2] == """#= $(joinpath(root, file)):4 =# @test true"""
    @test Expr(only(last(test_data))) == :(using Test)

    file = "test-b.jl"
    full_map, tabled_keys = build_file_testset_map(root, [file])
    testinfo = only(keys(full_map))
    @test testinfo == TestsetInfo("\"Challenge for JuliaSyntax\"", file, 1, 6)
end
