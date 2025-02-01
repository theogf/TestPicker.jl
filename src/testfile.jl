function get_display_file_cmd()
    if !isempty(Sys.which("bat"))
        "bat --color=always --style=numbers"
    elseif !isempty(Sys.which("cat"))
        "cat"
    else
        nothing
    end
end

"Find all test files that are close to `query`."
function find_related_testfile(query::AbstractString)
    root, files = get_test_files()
    # Run fzf to get a relevant file.
    display_file_cmd = get_display_file_cmd()
    preview_cmd = "$(get_display_file_cmd()) $(root)/{-1}"
    files = fzf() do exe
        cmd = if isnothing(display_file_cmd)
            `$(exe) --m --query $(query)`
        else
            `$(exe) --preview $(preview_cmd) -m --query $(query)`
        end
        readlines(pipeline(Cmd(cmd; ignorestatus=true); stdin=IOBuffer(join(files, '\n'))))
    end
    if isempty(files)
        @debug "Could not find any files with query $query"
        files
    else
        joinpath.(Ref(root), files)
    end
end

"""
    get_test_files() -> String, Vector{String}

Get full collection of test files for the given package. Return the absolute path of the test directory and 
the collection of test files as paths relative to it.
"""
function get_test_files()
    pkg = current_pkg_name()
    test_dir = get_test_dir(ctx_and_pkgspec(pkg)...)
    isdir(test_dir) || error(
        "the test directory $(test_dir) does not exist, you need to activate your package environment first",
    )
    # Recursively get a list of julia files.
    return test_dir,
    mapreduce(vcat, walkdir(test_dir)) do (root, _, files)
        relpath.(filter(endswith(".jl"), joinpath.(Ref(root), files)), Ref(test_dir))
    end
end

"Run fzf with the given input and if the file is a valid one run the test with the Test environment."
function find_and_run_test_file(query::AbstractString)
    pkg = current_pkg_name()
    files = find_related_testfile(query)
    for file in files
        if isempty(file)
        elseif !isfile(file)
            @error "File $(file) could not be found, this sounds like a bug, please report it on https://github.com/theogf/TestPicker.jl/issues/new."
        else
            run_test_file(file, pkg)
        end
    end
end

function run_test_file(file::AbstractString, pkg::AbstractString)
    @info "Executing test file $(file)"

    testset_name = "$(pkg) - $(file)"
    ex = :(@testset $testset_name begin
        include($file)
    end)
    return eval_in_module(ex, pkg)
end
