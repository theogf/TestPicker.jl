"Find all test files that are close to `query`."
function find_related_testfile(query::AbstractString)
    root, files = get_test_files()
    # Run fzf to get a relevant file.
    preview_cmd = []
    files = fzf() do fzf_exe
        bat() do bat_exe
            cmd = Cmd(
                String[
                    fzf_exe,
                    "--preview",
                    "$(bat_exe) --color=always --style=numbers {-1}",
                    "-m",
                    "--query",
                    query,
                ],
            )
            readlines(
                pipeline(
                    Cmd(cmd; ignorestatus=true, dir=root);
                    stdin=IOBuffer(join(files, '\n')),
                ),
            )
        end
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
    pkg = current_pkg()
    ctx = Context()
    isinstalled!(ctx, pkg) || throw(ArgumentError("$pkg not installed 👻"))
    test_dir = get_test_dir(ctx, pkg)
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
    pkg = current_pkg()
    files = find_related_testfile(query)
    LATEST_EVAL[] = TestInfo[]
    for file in files
        if isempty(file)
        elseif !isfile(file)
            @error "File $(file) could not be found, this sounds like a bug, please report it on https://github.com/theogf/TestPicker.jl/issues/new."
        else
            run_test_file(file, pkg)
        end
    end
end

function run_test_file(file::AbstractString, pkg::PackageSpec)
    testset_name = "$(pkg.name) - $(file)"
    ex = :(@testset $testset_name begin
        include($file)
    end)
    test = TestInfo(ex, file, "", 0)
    push!(LATEST_EVAL[], test)
    return eval_in_module(test, pkg)
end
