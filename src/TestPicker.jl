module TestPicker

using fzf_jll: fzf
using REPL
using REPL: LineEdit
using JuliaSyntax
using TestEnv

include("repl.jl")
include("testblocks.jl")

# Fetch the current package name given the active project.
current_pkg() = basename(dirname(Base.active_project()))
current_pkg_dir() = dirname(Base.active_project())

function find_related_testfile(str::AbstractString)
    dir = current_pkg_dir()
    test_dir = joinpath(dir, "test")
    isdir(test_dir) || error(
        "the test directory $(test_dir) does not exist, you need to activate your package environment first",
    )
    # Recursively get a list of julia files.
    files = mapreduce(vcat, walkdir(test_dir)) do (root, _, files)
        relpath.(filter(endswith(".jl"), joinpath.(Ref(root), files)), Ref(test_dir))
    end
    # Run fzf to get a relevant file.
    file = fzf() do exe
        chomp(
            read(
                pipeline(
                    Cmd(`$(exe) --query $str`; ignorestatus=true);
                    stdin=IOBuffer(join(files, '\n')),
                ),
                String,
            ),
        )
    end
    if isempty(file)
        @debug "Could not find any file with query $str"
        file
    else
        joinpath(test_dir, file)
    end
end

"Run fzf with the given input and if the file is a valid one run the test with the Test environment."
function find_and_run_test_file(query::AbstractString)
    pkg = current_pkg()
    file = find_related_testfile(query)
    if isempty(file)
    elseif !isfile(file)
        @error "File $(file) could not be found, this sounds like a bug, please report it on https://github.com/theogf/TestPicker.jl/issues/new."
    else
        run_test_file(file, pkg)
    end
end

function run_test_file(file::AbstractString, pkg)
    @info "Executing test file $(file)"
    TestEnv.activate(pkg) do
        Base.include(Main, file)
    end
end

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
