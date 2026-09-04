"""
    workspace_pkgs(ctx::Context=Context()) -> Vector{PackageSpec}

Packages of the *other* projects belonging to the workspace of the active environment.

Julia 1.12 lets a project gather several projects sharing a single manifest, a workspace:

```toml
# Project.toml at the root of the repository
[workspace]
projects = ["PkgA", "PkgB", "PkgA/docs"]
```

`Pkg` resolves the whole workspace whenever any of its projects is active, so every member
is listed in `Context().env.workspace`, be it the root project (when a member is active) or
the members (when the root is active), the active project itself excepted.

Only the members that are packages, i.e. that carry both a `name` and a `uuid`, are
returned: a `docs` or `test` sub-project is a plain environment and holds no test of its
own. Returns an empty vector on Julia versions without workspaces.
"""
function workspace_pkgs(ctx::Context=Context())
    # `EnvCache` only grew a `workspace` field with the introduction of workspaces in 1.12.
    hasproperty(ctx.env, :workspace) || return PackageSpec[]
    pkgs = PackageSpec[]
    for (project_file, project) in ctx.env.workspace
        (isnothing(project.name) || isnothing(project.uuid)) && continue
        push!(
            pkgs,
            PackageSpec(;
                name=project.name,
                uuid=project.uuid,
                version=something(project.version, VersionNumber("0.0")),
                path=dirname(abspath(project_file)),
            ),
        )
    end
    # `ctx.env.workspace` is a `Dict`, sorting keeps the listing stable between calls.
    return sort!(pkgs; by=pkg -> pkg.name)
end

"""
    current_pkgs() -> Vector{PackageSpec}

Every package TestPicker should look for tests in, given the active environment.

That is the active package, if there is one, followed by the packages of its workspace (see
[`workspace_pkgs`](@ref)). Outside of a workspace this is simply `[current_pkg()]` and
TestPicker behaves as it always did.

Within a workspace, only the packages that do have a test directory are kept: a workspace
commonly gathers packages that carry no test of their own. Throws a `TestEnvError` when
there is nothing to test at all, e.g. when the active environment is a plain project that
is neither a package nor a workspace.
"""
function current_pkgs()
    ctx = Context()
    pkgs = PackageSpec[]
    isnothing(ctx.env.pkg) || push!(pkgs, ctx.env.pkg)
    append!(pkgs, workspace_pkgs(ctx))
    isempty(pkgs) && throw(
        TestEnvError(
            "trying to run the tests of a project that is neither a package nor a workspace",
        ),
    )
    # A lone package keeps the more helpful error message of `get_test_dir_from_pkg`.
    isone(length(pkgs)) && return pkgs
    testable = filter(pkg -> !isnothing(testdir_or_nothing(pkg)), pkgs)
    isempty(testable) && throw(
        TestEnvError(
            "none of the packages of the workspace ($(join(map(pkg -> pkg.name, pkgs), ", "))) has a test directory",
        ),
    )
    return testable
end

"""
    testdir_or_nothing(pkg::PackageSpec) -> Union{Nothing,String}

Same as [`get_test_dir_from_pkg`](@ref) but returns `nothing` instead of throwing when
`pkg` has no test directory, e.g. for a workspace member that carries no test.
"""
function testdir_or_nothing(pkg::PackageSpec)
    return try
        get_test_dir_from_pkg(pkg)
    catch
        nothing
    end
end

"""
    unique_pkgs(pkgs) -> Vector{PackageSpec}

Deduplicate `pkgs` by name and uuid, i.e. by what tells two packages apart in the results
file, e.g. to empty the results of each package only once when a selection spans several
packages of a workspace.
"""
function unique_pkgs(pkgs)
    return unique(pkg -> (pkg.name, pkg.uuid), collect(PackageSpec, pkgs))
end
