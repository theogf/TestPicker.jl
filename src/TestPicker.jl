module TestPicker

using bat_jll: get_bat_path
using fzf_jll: fzf
using JuliaSyntax
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
export TestBlockInterface, add_interface!

"""
    TestInfo

Container for test execution metadata and location information.

Stores essential information about a test's source location and context,
used for tracking test execution and displaying results.

# Fields
- `filename::String`: Source file containing the test
- `label::String`: Human-readable test identifier (e.g., testset name)
- `line::Int`: Line number where the test begins

# See also
[`EvalTest`](@ref), [`save_test_results`](@ref)
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

# Fields
- `ex::Expr`: The executable test expression (may include preamble and wrapper code)
- `info::TestInfo`: Metadata about the test's source and identification

# Usage
`EvalTest` objects are created during test parsing and stored in [`LATEST_EVAL`](@ref)
for re-execution and result tracking.

# See also
[`TestInfo`](@ref), [`eval_in_module`](@ref), [`LATEST_EVAL`](@ref)
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

# Type
`Ref{Union{Nothing,Vector{EvalTest}}}`: Initially `nothing`, becomes a vector after first test execution

# Usage
- Set automatically when tests are executed
- Can be re-run using the `-` command in test mode
- Cleared when new test files are executed (not individual test blocks)

# Examples
```julia
# In test mode REPL:
# Run some tests first, then:
test> -    # Re-runs the last executed tests
```
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

# Type
`Vector{TestBlockInterface}`: Collection of interface implementations

# Default Contents
- [`StdTestset`](@ref): Handles standard Julia `@testset` blocks

# Modification
Use [`add_interface!`](@ref) to register additional test block interfaces:

```julia
# Add support for custom test blocks
add_interface!(MyCustomTestInterface())
```

# See also
[`TestBlockInterface`](@ref), [`StdTestset`](@ref), [`add_interface!`](@ref)
"""
const INTERFACES = TestBlockInterface[StdTestset()]

"""
    add_interface!(interface::TestBlockInterface) -> Vector{TestBlockInterface}

Register a new test block interface with TestPicker.

Adds the provided interface to the global [`INTERFACES`](@ref) collection, enabling
TestPicker to recognize and process the corresponding test block types. Duplicates
are automatically removed to prevent redundant processing.

# Arguments
- `interface::TestBlockInterface`: The interface implementation to register

# Returns
- `Vector{TestBlockInterface}`: The updated interfaces collection

# Examples
```julia
# Define a custom interface
struct MyTestInterface <: TestBlockInterface end
# ... implement required methods ...

# Register with TestPicker
add_interface!(MyTestInterface())

# Now TestPicker will recognize your test blocks
```

# Side Effects
Modifies the global [`INTERFACES`](@ref) collection, affecting all subsequent
test parsing and execution operations.

# See also
[`INTERFACES`](@ref), [`TestBlockInterface`](@ref)
"""
add_interface!(interface::TestBlockInterface) = unique!(push!(INTERFACES, interface))

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
