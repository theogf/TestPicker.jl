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

struct TestInfo
    filename::String
    label::String
    line::Int
end
"Struct containing a ran object, either a testset or a file."
struct EvalTest
    ex::Expr
    info::TestInfo
end

const LATEST_EVAL = Ref{Union{Nothing,Vector{EvalTest}}}(nothing)

include("common.jl")
include("eval.jl")
include("testfile.jl")
include("testblockinterface.jl")
include("testblock.jl")
include("repl.jl")
include("results_viewer.jl")

const INTERFACES = TestBlockInterface[StdTestset()]

"Add a new interface, to the list of test block interfaces run by `TestPicker`, duplicates are automatically removed."
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
