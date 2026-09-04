"""
    TESTENV_CACHE

Cache for TestEnv temporary environments to avoid triggering recompilation on every test run.

This constant stores a mapping from `PackageSpec` objects to their corresponding
temporary test environment paths. Reusing these environments improves
performance by avoiding the overhead of recreating test environments.
"""
const TESTENV_CACHE = Dict{PackageSpec,String}()

"""
    clear_testenv_cache()

Clear the TestEnv cache to force recreation of test environments on next use.

Empties the [`TESTENV_CACHE`](@ref) dictionary, which will cause subsequent test
evaluations to create fresh test environments. This can be useful when test
dependencies have changed or when troubleshooting environment-related issues.
"""
clear_testenv_cache() = empty!(TESTENV_CACHE)

"""
    prepend_ex(ex, new_line::Expr) -> Expr

Prepend a new expression to an existing expression, handling block structure appropriately.

If the target expression is already a block, the new expression is prepended to the
beginning of the block. Otherwise, a new block is created containing both expressions.
"""
function prepend_ex(ex, new_line::Expr)
    if Meta.isexpr(ex, :block)
        Expr(:block, new_line, ex.args...)
    else
        Expr(:block, new_line, ex)
    end
end

"""
    eval_in_module(eval_test::EvalTest) -> Union{Nothing,TestSetException,TestPickerTestSetException}

Execute a test block in an isolated module with the appropriate test environment activated.

This function provides the core test execution functionality for TestPicker. It creates
a temporary module, activates the test environment of the package the test belongs to, and
evaluates the test code in isolation to prevent interference between different test runs.
The environment that was active on entry is restored afterwards, whatever it was: with a
workspace that is typically the workspace project itself rather than any of its packages.

Returns `nothing` when all tests pass successfully. Otherwise returns a `TestSetException`
(bare, unwrapped test code) or a [`TestPickerTestSetException`](@ref) (test code wrapped in
a [`TestPickerTestSet`](@ref), as done by [`run_testfile`](@ref) and [`testblock_list`](@ref))
when test failures are encountered.
"""
function eval_in_module(
    (; ex, info, pkg)::EvalTest
)::Union{Nothing,TestSetException,TestPickerTestSetException}
    (; filename, label, line) = info
    mod = gensym(pkg.name)
    # Whatever we activate along the way, this is what the session gets back at the end.
    active_project = Base.active_project()
    revise_ex = quote
        import TestPicker: Revise
        Revise.revise()
    end
    auto_precompile_state = get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", "")
    disable_precompilation_expr = :(ENV["JULIA_PKG_PRECOMPILE_AUTO"] = 0)
    restore_precompilation_state =
        :(ENV["JULIA_PKG_PRECOMPILE_AUTO"] = $(auto_precompile_state))
    testenv_expr = if haskey(TESTENV_CACHE, pkg)
        quote
            $(disable_precompilation_expr)
            import TestPicker: Pkg
            Pkg.activate($(TESTENV_CACHE[pkg]); io=devnull)
        end
    else
        # `TestEnv` builds the test environment out of the *active* project, so we first
        # activate the project of the package itself. This is what makes a package of a
        # workspace work: the active project may well be the workspace root, which holds
        # none of the dependencies of its members.
        activate_pkg_expr = if isnothing(pkg.path)
            nothing
        else
            :(Pkg.activate($(pkg.path); io=devnull))
        end
        quote
            $(disable_precompilation_expr)
            import TestPicker: Pkg, TestEnv, TESTENV_CACHE
            $(activate_pkg_expr)
            TESTENV_CACHE[$pkg] = TestEnv.activate($(pkg.name))
        end
    end

    test_content = prepend_ex(ex, :(using TestPicker.Test))
    test_content = prepend_ex(test_content, :(using TestPicker: TestPicker))
    # `@testset TestPickerTestSet ...` requires an unqualified `Symbol`, so it must be
    # brought into scope directly rather than referenced as `TestPicker.TestPickerTestSet`.
    test_content = prepend_ex(test_content, :(using TestPicker: TestPickerTestSet))

    module_expr = Expr(:module, true, mod, test_content)

    top_ex = Expr(:toplevel, testenv_expr, module_expr)

    env_return = quote
        Base.set_active_project($(active_project))
        $(restore_precompilation_state)
    end
    clean_module = quote
        for name in names($mod; all=true)
            try
                var = getproperty($mod, name)
                if !isconst($mod, name)
                    setproperty!($mod, name, nothing)
                end
            catch e
                if isa(e, UndefVarError)
                    continue
                else
                    rethrow()
                end
            end
        end
    end
    root = get_test_dir_from_pkg(pkg)
    # We fetch `dir` such that relative include paths still work as expected.
    dir = dirname(joinpath(root, filename))
    if !isempty(label)
        @info "Executing testblock $(label) from $(filename):$(line)"
    else
        @info "Executing test file $(filename) in the test environment of $(pkg.name)"
    end
    @debug "Evaluating code block" top_ex
    result = nothing
    try
        # cd acts such that also evaled expressions in `Main` are affected.
        cd(dir) do
            Core.eval(Main, revise_ex)
            Core.eval(Main, top_ex)
        end
    catch e
        e isa Union{TestSetException,TestPickerTestSetException} || rethrow()
        save_test_results(e, info, pkg)
        result = e
    finally
        Core.eval(Main, env_return)
        Core.eval(Main, clean_module)
    end
    return result
end
