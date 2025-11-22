module TestPicker

using bat_jll: get_bat_path
using fzf_jll: fzf
using JuliaSyntax
using JuliaSyntax: @K_str, sourcetext
using InteractiveUtils: editor
using Pkg
using Pkg: PackageSpec
using Pkg.Types: Context
using REPL
using REPL: LineEdit, Terminals
using Revise: Revise
using Test
using TestEnv
using TestEnv: TestEnvError, get_test_dir, isinstalled!

export clear_testenv_cache
export TestBlockInterface, add_interface!, replace_interface!

"""
    TestInfo

Container for test execution metadata and location information.

Stores essential information about a test's source location and context,
used for tracking test execution and displaying results.
"""
struct TestInfo
    filename::String
    label::String
    line::Int
end

"""
    EvalTest

Container for executable test code and its associated metadata.

Combines a Julia expression representing test code with metadata about its source
and context. Used throughout TestPicker for tracking and executing tests.
"""
struct EvalTest
    ex::Expr
    info::TestInfo
end

"""
    LATEST_EVAL

Global reference to the most recently executed test evaluations.

Stores a vector of [`EvalTest`](@ref) objects representing the last set of tests
that were executed. This allows for re-running the same tests without going
through the selection interface again.
"""
const LATEST_EVAL = Ref{Union{Nothing,Vector{EvalTest}}}(nothing)

include("common.jl")
include("eval.jl")
include("testfile.jl")
include("testblockinterface.jl")
include("testblock.jl")
include("repl.jl")
include("results_viewer.jl")

"""
    INTERFACES

Global collection of test block interfaces used by TestPicker.

Contains all registered [`TestBlockInterface`](@ref) implementations that TestPicker
uses to recognize and parse different types of test blocks. By default includes
[`StdTestset`](@ref) for standard `@testset` blocks.
"""
const INTERFACES = TestBlockInterface[StdTestset()]

"""
    add_interface!(interface::TestBlockInterface) -> Vector{TestBlockInterface}

Register a new test block interface with TestPicker.

Adds the provided interface to the global [`INTERFACES`](@ref) collection, enabling
TestPicker to recognize and process the corresponding test block types. Duplicates
are automatically removed to prevent redundant processing.
"""
add_interface!(interface::TestBlockInterface) = unique!(push!(INTERFACES, interface))

"""
    replace_interface!(interface::TestBlockInterface) -> Vector{TestBlockInterface}

Similar to `add_interface!` but empty the interface first before adding the new one so that it becomes the unique interface.
"""
replace_interface!(interface::TestBlockInterface) = push!(empty!(INTERFACES), interface)

function __init__()
    # Add the REPL mode to the current active REPL.
    if isdefined(Base, :active_repl)
        init_test_repl_mode(Base.active_repl)
    else
        atreplinit() do repl
            if isinteractive() && repl isa REPL.LineEditREPL
                if !isdefined(repl, :interface)
                    repl.interface = REPL.setup_interface(repl)
                end
                init_test_repl_mode(repl)
            end
        end
    end
end

end
