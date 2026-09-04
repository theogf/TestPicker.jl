using Test
using JuliaSyntax
using Pkg
using Pkg.Types: PackageSpec
using TestPicker
using TestPicker: TestBlockInfo, StdTestset, SyntaxBlock, EvalResult, TestFile
using TestPicker:
    get_syntax_blocks,
    get_testfiles,
    get_matching_files,
    build_testblocks,
    pick_testblock,
    istestblock,
    fzf_testblock,
    testblock_list,
    refresh_stale_test

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

@testset "Matching test files of several packages" begin
    pkg = PackageSpec(; name="TestPicker", path=pkgdir(TestPicker))
    other = PackageSpec(; name="Other", path=pkgdir(TestPicker))
    root = joinpath(pkgdir(TestPicker), "test")
    files = [
        TestFile(pkg, root, "sandbox/test-a.jl", "TestPicker/sandbox/test-a.jl"),
        TestFile(other, root, "sandbox/test-a.jl", "Other/sandbox/test-a.jl"),
    ]
    # A query naming the package only keeps the files of that package.
    matched = get_matching_files("Other/test-a", files)
    @test only(matched).pkg == other
    @test length(get_matching_files("test-a", files)) == 2
end

@testset "Build test block maps" begin
    pkg = PackageSpec(; name="TestPicker", path=pkgdir(TestPicker))
    root = joinpath(pkgdir(TestPicker), "test", "sandbox")
    file = TestFile(pkg, root, "test-a.jl")
    interfaces = [StdTestset()]
    entries = build_testblocks(interfaces, [file], root)
    entry = only(values(entries))
    @test entry.info == TestBlockInfo("I am a testset", file.name, 3, 7)
    @test entry.file == file
    # The record shows the block and points the preview at the file and its line range.
    record = split(only(keys(entries)), TestPicker.separator())
    @test contains(record[1], "I am a testset")
    @test record[2] == file.name
    @test record[3] == "3"
    @test record[4] == "7"
    syntax_block = entry.block
    @test syntax_block isa SyntaxBlock
    string_version = string(Base.remove_linenums!(Expr(syntax_block.testblock)))
    stripped_lines = strip.(split(string_version, '\n'))
    @test first(stripped_lines) ==
        """#= $(joinpath(root, file.name)):3 =# @testset "I am a testset" begin"""
    @test stripped_lines[2] == """#= $(joinpath(root, file.name)):4 =# @test true"""
    @test Expr(only(syntax_block.preamble)) == :(using Test)

    file = TestFile(pkg, root, "test-b.jl")
    entries = build_testblocks(interfaces, [file], root)
    @test only(values(entries)).info ==
        TestBlockInfo("Challenge for JuliaSyntax", file.name, 1, 6)
end

@testset "Test blocks of several packages stay apart" begin
    # Two packages of a workspace can hold blocks that only differ by the package they
    # belong to; the picker must still offer both.
    pkg = PackageSpec(; name="TestPicker", path=pkgdir(TestPicker))
    other = PackageSpec(; name="Other", path=pkgdir(TestPicker))
    root = joinpath(pkgdir(TestPicker), "test", "sandbox")
    files = [
        TestFile(pkg, root, "test-a.jl", "TestPicker/test-a.jl"),
        TestFile(other, root, "test-a.jl", "Other/test-a.jl"),
    ]
    entries = build_testblocks([StdTestset()], files, root)
    @test length(entries) == 2
    @test issetequal([entry.file.pkg for entry in values(entries)], [pkg, other])
end

@testset "Nested testsets fetching" begin
    root = joinpath(pkgdir(TestPicker), "test", "sandbox", "test-subdir")
    file = "test-file-c.jl"
    interfaces = [StdTestset()]
    syntax_blocks = get_syntax_blocks(interfaces, joinpath(root, file))
    @test length(syntax_blocks) == 3
    # Check the first top testset
    syntax_block = first(syntax_blocks)
    @test no_indentation(JuliaSyntax.sourcetext(syntax_block.testblock)) == """
@testset "First level" begin
a = 2
@testset "Second level" begin
@test c == 3
f(2)
d = 4
end
end"""
    @test JuliaSyntax.sourcetext.(syntax_block.preamble) == ["using Test"]

    # Check the next second level testset
    next_syntax_block = syntax_blocks[2]
    @test no_indentation(JuliaSyntax.sourcetext(next_syntax_block.testblock)) == """
@testset "Second level" begin
@test c == 3
f(2)
d = 4
end"""
    @test no_indentation.(JuliaSyntax.sourcetext.(next_syntax_block.preamble)) ==
        ["using Test", "a = 2"]

    # Check another top level to ensure there is no preamble propagation
    last_syntax_block = syntax_blocks[3]
    @test no_indentation(JuliaSyntax.sourcetext(last_syntax_block.testblock)) == """
@testset "First level - B" begin
a = 1
b = 2
@test a == b
@test w == 1
end"""
    @test no_indentation.(JuliaSyntax.sourcetext.(last_syntax_block.preamble)) ==
        ["using Test", "x = 5"]
end

@testset "Non-interactive testblock selection" begin
    pkg = PackageSpec(; name="TestPicker", path=pkgdir(TestPicker))
    root = joinpath(pkgdir(TestPicker), "test", "sandbox")
    interfaces = [StdTestset()]
    entries = build_testblocks(interfaces, [TestFile(pkg, root, "test-a.jl")], root)

    # Test selecting syntax_blocks with a query that matches
    choices = pick_testblock(entries, "testset", root; interactive=false)
    @test !isempty(choices)
    @test length(choices) == 1  # Only one testset in test-a.jl

    # Test selecting syntax_blocks with a query that doesn't match
    choices = pick_testblock(entries, "nonexistent", root; interactive=false)
    @test isempty(choices)

    # Test with multiple files and nested testsets
    root_subdir = joinpath(pkgdir(TestPicker), "test", "sandbox", "test-subdir")
    entries_c = build_testblocks(
        interfaces, [TestFile(pkg, root_subdir, "test-file-c.jl")], root_subdir
    )

    # Should match both "First level" testsets
    choices = pick_testblock(entries_c, "First", root_subdir; interactive=false)
    @test length(choices) == 2  # "First level" and "First level - B"

    # Should match only "Second level" testset
    choices = pick_testblock(entries_c, "Second", root_subdir; interactive=false)
    @test length(choices) == 1
end

@testset "fzf_testblock return type" begin
    interfaces = [StdTestset()]

    # `fzf_testblock` picks its packages from the active environment, which under
    # `Pkg.test` is the sandbox test environment rather than the package itself.
    Pkg.activate(pkgdir(TestPicker)) do
        # Test that fzf_testblock returns a vector when syntax_blocks match
        result = fzf_testblock(interfaces, "test-a", "testset"; interactive=false)
        @test result isa Vector
        @test all(r -> r isa EvalResult, result)
    end
end

@testset "Refreshing stale reruns" begin
    # `root` must match `get_test_dir_from_pkg(pkg)` (the package's "test" directory),
    # since `refresh_stale_test`/`build_eval_test` resolve the file's content hash from
    # `pkg`.
    root = joinpath(pkgdir(TestPicker), "test")
    pkg = PackageSpec(; name="TestPicker", path=pkgdir(TestPicker))
    interfaces = [StdTestset()]
    file = TestFile(pkg, root, "sandbox/test-rerun-tmp.jl")
    path = abspath(file)

    write(
        path,
        """
        using Test

        @testset "rerun target" begin
            @test true
        end
        """,
    )
    try
        entries = build_testblocks(interfaces, [file], root)
        choices = pick_testblock(entries, "rerun target", root; interactive=false)
        test = only(testblock_list(choices, entries))
        @test test.info.line == 3
        @test test.pkg == pkg

        # Unmodified file: the exact same test is returned untouched.
        @test refresh_stale_test(test) === test

        # Modify the file so the same block now starts further down.
        write(
            path,
            """
            using Test

            # A comment shifting the block down.

            @testset "rerun target" begin
                @test true
            end
            """,
        )

        refreshed = refresh_stale_test(test)
        @test refreshed !== test
        @test refreshed.info.line == 5
        @test refreshed.info.label == "rerun target"

        # If the label is now ambiguous, give up rather than guessing which block is meant
        # — the stale test is dropped (`nothing`), not silently re-run.
        write(
            path,
            """
            using Test

            @testset "rerun target" begin
                @test true
            end

            @testset "rerun target" begin
                @test true
            end
            """,
        )
        @test_logs (:warn,) match_mode = :any refresh_stale_test(refreshed)
        @test isnothing(refresh_stale_test(refreshed))

        # If the block can no longer be found, it's dropped too, instead of rerunning
        # outdated code.
        write(path, "using Test\n")
        @test_logs (:warn,) match_mode = :any refresh_stale_test(refreshed)
        @test isnothing(refresh_stale_test(refreshed))

        # If the file itself disappears, same thing.
        rm(path)
        @test_logs (:warn,) match_mode = :any refresh_stale_test(refreshed)
        @test isnothing(refresh_stale_test(refreshed))
    finally
        rm(path; force=true)
    end
end
