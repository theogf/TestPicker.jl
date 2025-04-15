module TestPicker

using bat_jll: bat
using fzf_jll: fzf
using JuliaSyntax
using Pkg
using Pkg: PackageSpec
using Pkg.Types: Context
using REPL
using REPL: LineEdit
using Revise: Revise
using ripgrep_jll: rg
using Test
using TestEnv
using TestEnv: TestEnvError, get_test_dir, isinstalled!

export clear_testenv_cache

struct TestInfo
    ex::Expr
    filename::String
    testset::String
    line::Int
end

const LATEST_EVAL = Ref{Union{Nothing,Vector{TestInfo}}}(nothing)

include("common.jl")
include("eval.jl")
include("testfile.jl")
include("testblock.jl")
include("repl.jl")
include("results_viewer.jl")

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
