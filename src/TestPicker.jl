module TestPicker

using fzf_jll: fzf
using REPL
using REPL: LineEdit
using JuliaSyntax
using TestEnv
using TestEnv: current_pkg_name, get_test_dir, ctx_and_pkgspec
using Pkg
using Test

include("eval.jl")
include("testfile.jl")
include("testblock.jl")
include("repl.jl")

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
