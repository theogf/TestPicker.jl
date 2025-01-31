module TestPicker

using fzf_jll: fzf
using REPL
using REPL: LineEdit
using JuliaSyntax
using TestEnv
using Test

include("repl.jl")
include("testfile.jl")
include("testblock.jl")

# Fetch the current package name given the active project.
current_pkg_dir() = dirname(Base.active_project())
current_pkg() = basename(current_pkg_dir())

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

function eval_in_module(ex::Expr, pkg::AbstractString)
    mod = gensym(pkg)
    module_ex = Expr(:toplevel, :(module $mod
        using TestPicker: TestEnv
        using TestPicker.Test
        TestEnv.activate($pkg) do
            $(ex)
        end
    end))
    push!(module_ex.args, :(nothing))
    return Core.eval(Main, module_ex)
end

end
