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
    testenv_expr = if haskey(TESTENV_CACHE, pkg)
        quote
            import TestPicker: Pkg
            Pkg.activate($(TESTENV_CACHE[pkg]); io=devnull)
        end
    else
        quote
            import TestPicker: Pkg, TestEnv, TESTENV_CACHE
            TESTENV_CACHE[$pkg] = TestEnv.activate($(pkg.name))
        end
    end

    test_content = Expr(:block, :(using TestPicker.Test), ex)

    module_expr = Expr(:module, true, mod, test_content)

    top_ex = Expr(:toplevel, testenv_expr, module_expr, :nothing)

    env_return = quote
        Pkg.activate($(pkg.path); io=devnull)
    end
    if !isempty(testset)
        @info "Executing testset $(testset) from $(filename):$(line)"
    else
        @info "Executing test file $(filename)"
    end
    withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
        try
            Core.eval(Main, top_ex)
        finally
            Core.eval(Main, env_return)
        end
    end
end
