"Find all test files that are close to `query`."
function select_test_files(query::AbstractString, pkg::PackageSpec=current_pkg())
    root, files = get_test_files(pkg)
    # Run fzf to get a relevant file.
    fzf_args = [
        "-m", # Allow multiple choices.
        "--preview", # Preview the given file with bat.
        "$(get_bat_path()) --color=always --style=numbers {-1}",
        "--header",
        "Selecting test file(s)",
        "--query", # Initial file query.
        query,
    ]
    cmd = `$(fzf()) $(fzf_args)`
    files = readlines(
        pipeline(Cmd(cmd; ignorestatus=true, dir=root); stdin=IOBuffer(join(files, '\n')))
    )
    if isempty(files)
        @debug "Could not find any relevant files with query \"$query\"."
        files
    else
        joinpath.(Ref(root), files)
    end
end

"""
    get_test_files(pkg::PackageSpec = current_pkg()) -> String, Vector{String}

Get full collection of test files for the given package. Return the absolute path of the test directory and 
the collection of test files as paths relative to it.
"""
function get_test_files(pkg::PackageSpec=current_pkg())
    test_dir = get_test_dir_from_pkg(pkg)
    # Recursively get a list of julia files.
    return test_dir,
    mapreduce(vcat, walkdir(test_dir)) do (root, _, files)
        relpath.(filter(endswith(".jl"), joinpath.(Ref(root), files)), Ref(test_dir))
    end
end
function get_test_dir_from_pkg(pkg::PackageSpec=current_pkg())
    ctx = Context()
    isinstalled!(ctx, pkg) || throw(ArgumentError("$pkg not installed 👻"))
    test_dir = get_test_dir(ctx, pkg)
    isdir(test_dir) || error(
        "the test directory $(test_dir) does not exist, you need to activate your package environment first",
    )
    return test_dir
end

"Run fzf with the given input and if the file is a valid one run the test with the Test environment."
function fzf_testfile(query::AbstractString)
    pkg = current_pkg()
    files = select_test_files(query, pkg)
    return run_test_files(files, pkg)
end

function run_test_files(files::AbstractVector{<:AbstractString}, pkg::PackageSpec)
    # We return early to not empty the LATEST_EVAL
    isempty(files) && return nothing
    # Reset the latest eval data.
    LATEST_EVAL[] = EvalTest[]
    clean_results_file(pkg)
    for file in files
        if isempty(file)
        elseif !isfile(file)
            @error "File $(file) could not be found, this sounds like a bug, please report it on https://github.com/theogf/TestPicker.jl/issues/new."
        else
            run_test_file(file, pkg)
        end
    end
end

"Build and evaluate the expression for the given test file."
function run_test_file(file::AbstractString, pkg::PackageSpec)
    testset_name = "$(pkg.name) - $(file)"
    test_info = TestInfo(file, "", 0)
    ex = quote
        using TestPicker: TestPicker
        try
            @testset $testset_name begin
                include($file)
            end
        catch e
            !(e isa TestSetException) && rethrow()
            TestPicker.save_test_results(e, $(test_info), $(pkg))
        end
    end
    test = EvalTest(ex, test_info)
    if !isnothing(LATEST_EVAL[])
        push!(LATEST_EVAL[], test)
    else
        LATEST_EVAL[] = [test]
    end
    return eval_in_module(test, pkg)
end
