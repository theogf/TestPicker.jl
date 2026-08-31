module TestPicker

using CRC32c: crc32c
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
using Markdown
using JSON
using Base.StackTraces
using TestEnv: TestEnvError, get_test_dir, isinstalled!
using PrecompileTools

export clear_testenv_cache
export inspect_error
export TestBlockInfo
export TestBlockInterface, add_interface!, replace_interface!
export TestItemInterface, add_testitem_interface!

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

`content_hash` is the CRC32c checksum of the source file's contents when `ex` was
captured, so that a rerun (`test> -`) can detect that the file changed in the meantime
(a content hash catches edits that a modification time can miss, e.g. on filesystems
with coarse mtime resolution, or a save that happens to restore the original mtime) and
try to relocate the block instead of blindly replaying a stale expression; see
[`refresh_stale_test`](@ref).
"""
struct EvalTest
    ex::Expr
    info::TestInfo
    content_hash::UInt32
end

EvalTest(ex::Expr, info::TestInfo) = EvalTest(ex, info, 0x00000000)

"""
    EvalResult{T}
    
Result from evaluating a given `EvalTest`.
"""
struct EvalResult{T}
    success::Bool
    info::TestInfo
    result::T
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
include("trace.jl")
include("testset.jl")
include("eval.jl")
include("testfile.jl")
include("testblockinterface.jl")
include("testblock.jl")
include("docs.jl")
include("repl.jl")
include("results_viewer.jl")
include("error_inspector.jl")
include("precompilation.jl")

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

"""
    add_testitem_interface!() -> Vector{TestBlockInterface}

Register [`TestItemInterface`](@ref) with TestPicker so that `@testitem` blocks are
recognized alongside standard `@testset`s.

Shorthand for `add_interface!(TestItemInterface())`.
"""
add_testitem_interface!() = add_interface!(TestItemInterface())

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
