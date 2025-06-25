"""
We reuse the temp environment made by `TestEnv` to avoid trigger recompilation every time.

This can be cleared with `clear_testenv_cache()`.
"""
const TESTENV_CACHE = Dict{PackageSpec,String}()

clear_testenv_cache() = empty!(TESTENV_CACHE)

"Create a new block by either preprending a `new_line` to an existing block or
creating a new block with the two expresssions."
function prepend_ex(ex, new_line::Expr)
    if Meta.isexpr(ex, :block)
        Expr(:block, new_line, ex.args...)
    else
        Expr(:block, new_line, ex)
    end
end

# We add this dummy macro to override the `@testitem` we encounter in tests. This will simply call `run_test` by providing the filename and testset name as filters (and assuming that the package path is available in `__pkg_path__`). We will add the path in `eval_in_module`
macro testitem(name, args...)
    filename = __source__.file |> string
    :(TestItemRunner.run_tests(__pkg_path__; filter = ti -> (ti.filename == $filename && ti.name == $name))) |> esc
end

"Evaluate `ex` scoped in a `Module`, while activating the test environment of `pkg`."
function eval_in_module((; ex, info)::EvalTest, pkg::PackageSpec)
    (; filename, testset, line) = info
    mod = gensym(pkg.name)
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
            ENV["JULIA_DEBUG"] = "loading"
            import TestPicker: Pkg
            Pkg.activate($(TESTENV_CACHE[pkg]); io=devnull)
        end
    else
        quote
            $(disable_precompilation_expr)
            import TestPicker: Pkg, TestEnv, TESTENV_CACHE
            TESTENV_CACHE[$pkg] = TestEnv.activate($(pkg.name))
        end
    end

    test_content = prepend_ex(ex, :(const __pkg_path__ = $(pkg.path))) # Put the pkg path at the top level of the generated module
    test_content = prepend_ex(test_content, :(using TestPicker.TestItemRunner: TestItemRunner, @testsnippet, @testmodule)) # @testsnippet and @testmodule will just return nothing and are needed to avoid errors in tests if these are present in files
    test_content = prepend_ex(test_content, :(using TestPicker.Test))
    test_content = prepend_ex(test_content, :(using TestPicker: TestPicker, @testitem))

    module_expr = Expr(:module, true, mod, test_content)

    top_ex = Expr(:toplevel, testenv_expr, module_expr, :nothing)

    env_return = quote
        Pkg.activate($(pkg.path); io=devnull)
        $(restore_precompilation_state)
    end
    clean_module = quote
        for name in names($mod; all=true)
            try
                var = getproperty($mod, name)
                if !isconst($mod, name)
                    setproperty!($mod, name, nothing)
                end
            catch
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
    if !isempty(testset)
        @info "Executing testset $(testset) from $(filename):$(line)"
    else
        @info "Executing test file $(filename)"
    end
    try
        # cd acts such that also evaled expressions in `Main` are affected.
        cd(dir) do
            Core.eval(Main, revise_ex)
            Core.eval(Main, top_ex)
        end
    finally
        Core.eval(Main, env_return)
        Core.eval(Main, clean_module)
    end
end
