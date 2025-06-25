using Test
using JuliaSyntax
using TestPicker
using TestPicker: TestsetInfo
using TestPicker:
    get_testsets_with_preambles,
    get_test_files,
    get_matching_files,
    build_file_testset_map,
    pick_testset,
    testnode_symbols,
    is_testnode

function no_indentation(s::AbstractString)
    return replace(s, r"^\s+"m => "")
end

@testset "Testset node detection" begin
    s = """
    @testset "asda" begin
      @test true
    end
    """

    s2 = """
    using Pkg
    """

    s3 = """
    @foo "aaaa" begin
    end
    """

    root = parseall(SyntaxNode, s)
    @test is_testnode(only(JuliaSyntax.children(root)))
    root = parseall(SyntaxNode, s2)
    @test !is_testnode(only(JuliaSyntax.children(root)))
    root = parseall(SyntaxNode, s3)
    node = only(JuliaSyntax.children(root))
    @test !is_testnode(node)
    @test withenv("TESTPICKER_NODES" => "@foo") do
        is_testnode(node)
    end
    @test_logs (:warn,) withenv("TESTPICKER_NODES" => "foobar") do
        is_testnode(node)
    end
    @test withenv("TESTPICKER_NODES" => "@foo,@bar") do
        testnode_symbols() == [Symbol("@testset"), Symbol("@testitem"), Symbol("@foo"), Symbol("@bar")]
    end
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
    @test only(keys(full_map)) == TestsetInfo("\"I am a testset\"", file, 3, 7)
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

@testset "Nested testsets fetching" begin
    root = joinpath(pkgdir(TestPicker), "test", "sandbox", "test-subdir")
    file = "test-file-c.jl"
    testsets_preambles = get_testsets_with_preambles(joinpath(root, file))
    @test length(testsets_preambles) == 3
    # Check the first top testset
    testset, preambles = first(testsets_preambles)
    @test no_indentation(JuliaSyntax.sourcetext(testset)) == """
@testset "First level" begin
a = 2
f(2)
@testset "Second level" begin
@test c == 3
d = 4
end
end"""
    @test JuliaSyntax.sourcetext.(preambles) == ["using Test"]

    # Check the next second level testset
    testset, preambles = testsets_preambles[2]
    @test no_indentation(JuliaSyntax.sourcetext(testset)) == """
@testset "Second level" begin
@test c == 3
d = 4
end"""
    @test no_indentation.(JuliaSyntax.sourcetext.(preambles)) ==
        ["using Test", "a = 2", "f(2)"]

    # Check another top level to ensure there is no preamble propagation
    testset, preambles = testsets_preambles[3]
    @test no_indentation(JuliaSyntax.sourcetext(testset)) == """
@testset "First level - B" begin
@test w == 1
end"""
    @test no_indentation.(JuliaSyntax.sourcetext.(preambles)) == ["using Test", "x = 5"]
end
