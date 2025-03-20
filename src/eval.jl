"Evaluate `ex` scoped in a `Module`, while activating the test environment of `pkg`."
function eval_in_module(ex::Expr, pkg::AbstractString)
    mod = gensym(pkg)
    testenv_expr = quote
        using TestPicker: TestEnv
        TestEnv.activate($pkg)
    end

    mod_content = Expr(:block, :(using TestPicker.Test), ex)

    module_expr = Expr(:module, true, mod, mod_content)

    top_ex = Expr(:toplevel, testenv_expr, module_expr, :nothing)

    env_return = quote
        using TestPicker: Pkg
        Pkg.activate($pkg; io=devnull)
    end
    try
        Core.eval(Main, top_ex)
    finally
        Core.eval(Main, env_return)
    end
end

"Evaluate the expression in the `Main` environment. It creates a dirty state but can be quicker to use with Revise on."
function eval_in_main(ex::Expr, pkg::AbstractString)
    testenv_expr = quote
        using TestPicker.Test
        using TestPicker: TestEnv
        TestEnv.activate($pkg)
    end
    
    env_return = quote
        using TestPicker: Pkg
        Pkg.activate($pkg; io=devnull)
    end

    mod_content = Expr(:block, testenv_expr, ex)

    try
        Core.eval(Main, mod_content)
    finally
        Core.eval(Main, env_return)
    end
end
