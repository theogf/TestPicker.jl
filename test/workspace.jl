using Test
using Pkg
using Pkg.Types: PackageSpec
using TestPicker
using TestPicker:
    TestFile,
    current_pkgs,
    get_test_dir_from_pkg,
    get_testfiles,
    select_testfiles,
    unique_pkgs,
    workspace_pkgs

"""
Write a Julia 1.12 workspace under `dir`:

- `PkgA` and `PkgB`, two packages with tests of their own,
- `PkgC`, a package without any test,
- `docs`, a plain sub-project, i.e. a member that is no package at all.
"""
function write_workspace(dir::AbstractString)
    write(
        joinpath(mkpath(dir), "Project.toml"),
        """
        [workspace]
        projects = ["PkgA", "PkgB", "PkgC", "docs"]
        """,
    )
    for (name, uuid) in [
        ("PkgA", "11111111-1111-1111-1111-111111111111"),
        ("PkgB", "22222222-2222-2222-2222-222222222222"),
        ("PkgC", "33333333-3333-3333-3333-333333333333"),
    ]
        write(
            joinpath(mkpath(joinpath(dir, name)), "Project.toml"),
            """
            name = "$(name)"
            uuid = "$(uuid)"
            version = "0.1.0"
            """,
        )
        write(
            joinpath(mkpath(joinpath(dir, name, "src")), "$(name).jl"),
            "module $(name)\nend\n",
        )
        # `PkgC` is the one member that has nothing to run.
        name == "PkgC" && continue
        write(
            joinpath(mkpath(joinpath(dir, name, "test")), "runtests.jl"),
            """
            using Test

            @testset "$(name) tests" begin
                @test true
            end
            """,
        )
    end
    write(
        joinpath(mkpath(joinpath(dir, "docs")), "Project.toml"),
        """
        [deps]
        """,
    )
    return dir
end

if VERSION < v"1.12"
    @testset "Workspaces are a Julia 1.12 feature" begin
        # Nothing to discover on a `Pkg` that knows nothing of workspaces.
        @test isempty(workspace_pkgs())
    end
else
    mktempdir() do dir
        ws = write_workspace(joinpath(dir, "workspace"))

        @testset "Workspace discovery from the root project" begin
            Pkg.activate(ws) do
                # The members that are packages, and only those: `docs` is left out.
                @test [pkg.name for pkg in workspace_pkgs()] == ["PkgA", "PkgB", "PkgC"]
                # And of those, only the ones that do have tests to offer.
                @test [pkg.name for pkg in current_pkgs()] == ["PkgA", "PkgB"]
                @test get_test_dir_from_pkg(first(current_pkgs())) ==
                    joinpath(ws, "PkgA", "test")
            end
        end

        @testset "Workspace discovery from a member" begin
            Pkg.activate(joinpath(ws, "PkgA")) do
                # The active package comes first, its siblings follow.
                @test [pkg.name for pkg in current_pkgs()] == ["PkgA", "PkgB"]
                # The root project of the workspace is no package, it is not offered.
                @test [pkg.name for pkg in workspace_pkgs()] == ["PkgB", "PkgC"]
            end
        end

        @testset "Test files across a workspace" begin
            Pkg.activate(ws) do
                pkgs = current_pkgs()
                files = get_testfiles(pkgs)
                @test files isa Vector{TestFile}
                # Both `runtests.jl` are offered, each under the name of its package.
                @test [file.label for file in files] == [joinpath("PkgA", "runtests.jl"), joinpath("PkgB", "runtests.jl")]
                @test [file.name for file in files] == ["runtests.jl", "runtests.jl"]
                @test [file.root for file in files] == [joinpath(ws, "PkgA", "test"), joinpath(ws, "PkgB", "test")]

                # A query naming a package selects the file of that package alone.
                mode, selected = select_testfiles("PkgB", pkgs; interactive=false)
                @test mode == :file
                @test only(selected).pkg.name == "PkgB"
                @test abspath(only(selected)) == joinpath(ws, "PkgB", "test", "runtests.jl")

                # And a query naming the file alone still offers both.
                _, both = select_testfiles("runtests", pkgs; interactive=false)
                @test length(both) == 2
                @test unique_pkgs(file.pkg for file in both) == pkgs
            end
        end
    end
end
