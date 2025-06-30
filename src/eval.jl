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
    eval_in_module(eval_test::EvalTest, pkg::PackageSpec) -> Nothing

Execute a test block in an isolated module with the appropriate test environment activated.

This function provides the core test execution functionality for TestPicker. It creates
a temporary module, activates the package's test environment, and evaluates the test
code in isolation to prevent interference between different test runs.

# Arguments
- `eval_test::EvalTest`: Contains the test expression and metadata
- `pkg::PackageSpec`: Package specification for environment setup

# Process Overview
1. **Environment Setup**: Activates test environment (cached or new)
2. **Module Creation**: Creates isolated module for test execution  
3. **Code Preparation**: Prepends necessary imports and setup code
4. **Execution**: Evaluates test in correct directory context with Revise support
5. **Cleanup**: Restores original environment and cleans temporary module

# Side Effects
- Temporarily changes active Pkg environment
- Creates and cleans up temporary module in Main
- May trigger Revise.revise() for code reloading
- Changes working directory during execution
- Outputs execution information via `@info`

# Environment Management
- Uses [`TESTENV_CACHE`](@ref) for performance optimization
- Temporarily disables auto-precompilation during setup
- Restores original environment and precompilation settings after execution

# Error Handling
- Ensures environment restoration even if test execution fails
- Cleans up temporary module variables in finally block
- Preserves original working directory

# Examples
```julia
# Execute a test block from an EvalTest object
test = EvalTest(:(using Test; @test 1+1 == 2), TestInfo("test.jl", "arithmetic", 1))
pkg = PackageSpec(name="MyPackage", path="/path/to/package")
eval_in_module(test, pkg)
```
"""
function eval_in_module((; ex, info)::EvalTest, pkg::PackageSpec)
    (; filename, label, line) = info
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

    test_content = prepend_ex(ex, :(using TestPicker.Test))
    test_content = prepend_ex(test_content, :(using TestPicker: TestPicker))

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
    if !isempty(label)
        @info "Executing testblock $(label) from $(filename):$(line)"
    else
        @info "Executing test file $(filename)"
    end
    @debug "Evaluating code block" top_ex
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
