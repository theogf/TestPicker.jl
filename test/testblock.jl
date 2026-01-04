using Test
using JuliaSyntax
using TestPicker
using TestPicker: TestBlockInfo, StdTestset, SyntaxBlock, EvalResult
using TestPicker:
    get_testblocks,
    get_testfiles,
    get_matching_files,
    build_info_to_syntax,
    pick_testblock,
    istestblock,
    fzf_testblock

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
    @testitem "aaaa" begin
    end
    """

    interface = StdTestset()
    root = parseall(SyntaxNode, s)
    @test istestblock(interface, only(JuliaSyntax.children(root)))
    root = parseall(SyntaxNode, s2)
    @test !istestblock(interface, only(JuliaSyntax.children(root)))
    root = parseall(SyntaxNode, s3)
    node = only(JuliaSyntax.children(root))
    @test !istestblock(interface, node)
end
@testset "Matching files" begin
    matched_files = get_matching_files("foo", ["test-foo", "test-bar"])
    @test matched_files == ["test-foo"]
    matched_files = get_matching_files("foo", ["test-foo", "foto", "test-bar"])
    @test issetequal(matched_files, ["test-foo", "foto"])
    matched_files = get_matching_files("foo", ["bar"])
    @test isempty(matched_files)
end

@testset "Build test block maps" begin
    root = joinpath(pkgdir(TestPicker), "test", "sandbox")
    file = "test-a.jl"
    interfaces = [StdTestset()]
    full_map, tabled_keys = build_info_to_syntax(interfaces, root, [file])
    @test length(full_map) == length(tabled_keys)
    @test only(keys(full_map)) == TestBlockInfo("\"I am a testset\"", file, 3, 7)
    syntax_block = only(values(full_map))
    @test syntax_block isa SyntaxBlock
    string_version = string(Base.remove_linenums!(Expr(syntax_block.testblock)))
    stripped_lines = strip.(split(string_version, '\n'))
    @test first(stripped_lines) ==
        """#= $(joinpath(root, file)):3 =# @testset "I am a testset" begin"""
    @test stripped_lines[2] == """#= $(joinpath(root, file)):4 =# @test true"""
    @test Expr(only(syntax_block.preamble)) == :(using Test)

    file = "test-b.jl"
    full_map, tabled_keys = build_info_to_syntax(interfaces, root, [file])
    testinfo = only(keys(full_map))
    @test testinfo == TestBlockInfo("\"Challenge for JuliaSyntax\"", file, 1, 6)
end

@testset "Nested testsets fetching" begin
    root = joinpath(pkgdir(TestPicker), "test", "sandbox", "test-subdir")
    file = "test-file-c.jl"
    interfaces = [StdTestset()]
    testblocks = get_testblocks(interfaces, joinpath(root, file))
    @test length(testblocks) == 3
    # Check the first top testset
    syntax_block = first(testblocks)
    @test no_indentation(JuliaSyntax.sourcetext(syntax_block.testblock)) == """
@testset "First level" begin
a = 2
f(2)
@testset "Second level" begin
@test c == 3
d = 4
end
end"""
    @test JuliaSyntax.sourcetext.(syntax_block.preamble) == ["using Test"]

    # Check the next second level testset
    next_syntax_block = testblocks[2]
    @test no_indentation(JuliaSyntax.sourcetext(next_syntax_block.testblock)) == """
@testset "Second level" begin
@test c == 3
d = 4
end"""
    @test no_indentation.(JuliaSyntax.sourcetext.(next_syntax_block.preamble)) ==
        ["using Test", "a = 2", "f(2)"]

    # Check another top level to ensure there is no preamble propagation
    last_syntax_block = testblocks[3]
    @test no_indentation(JuliaSyntax.sourcetext(last_syntax_block.testblock)) == """
@testset "First level - B" begin
@test w == 1
end"""
    @test no_indentation.(JuliaSyntax.sourcetext.(last_syntax_block.preamble)) ==
        ["using Test", "x = 5"]
end

@testset "Non-interactive testblock selection" begin
    root = joinpath(pkgdir(TestPicker), "test", "sandbox")
    file = "test-a.jl"
    interfaces = [StdTestset()]
    full_map, tabled_keys = build_info_to_syntax(interfaces, root, [file])

    # Test selecting testblocks with a query that matches
    choices = pick_testblock(tabled_keys, "testset", root; interactive=false)
    @test !isempty(choices)
    @test length(choices) == 1  # Only one testset in test-a.jl

    # Test selecting testblocks with a query that doesn't match
    choices = pick_testblock(tabled_keys, "nonexistent", root; interactive=false)
    @test isempty(choices)

    # Test with multiple files and nested testsets
    root_subdir = joinpath(pkgdir(TestPicker), "test", "sandbox", "test-subdir")
    file_c = "test-file-c.jl"
    full_map_c, tabled_keys_c = build_info_to_syntax(interfaces, root_subdir, [file_c])

    # Should match both "First level" testsets
    choices = pick_testblock(tabled_keys_c, "First", root_subdir; interactive=false)
    @test length(choices) == 2  # "First level" and "First level - B"

    # Should match only "Second level" testset
    choices = pick_testblock(tabled_keys_c, "Second", root_subdir; interactive=false)
    @test length(choices) == 1
end

@testset "fzf_testblock return type" begin
    interfaces = [StdTestset()]

    # Test that fzf_testblock returns a vector when testblocks match
    result = fzf_testblock(interfaces, "test-a", "testset"; interactive=false)
    @test result isa Vector
    @test all(r -> r isa EvalResult, result)
end
