"""
We reuse the temp environment made by `TestEnv` to avoid trigger recompilation every time.

This can be cleared with `clear_testenv_cache()`.
"""
const TESTENV_CACHE = Dict{PackageSpec,String}()

clear_testenv_cache() = empty!(TESTENV_CACHE)

"Evaluate `ex` scoped in a `Module`, while activating the test environment of `pkg`."
function eval_in_module(test::TestInfo, pkg::PackageSpec)
    (; ex, filename, testset, line) = test
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

    test_content = Expr(:block, :(using TestPicker.Test), ex)

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
    if !isempty(testset)
        @info "Executing testset $(testset) from $(filename):$(line)"
    else
        @info "Executing test file $(filename)"
    end
    try
        Core.eval(Main, revise_ex)
        Core.eval(Main, top_ex)
    finally
        Core.eval(Main, env_return)
        Core.eval(Main, clean_module)
    end
end
