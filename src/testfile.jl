"""
    select_test_files(query::AbstractString, pkg::PackageSpec=current_pkg()) -> (Symbol, String, Vector{String})

Interactively select test files using fzf based on a fuzzy search query.

Presents an fzf interface showing all test files for the package, with syntax-highlighted
preview using bat. Users can select multiple files and the query pre-filters the results.

Returns a tuple of (mode, root, files) where:
- mode is either :file or :testblock depending on whether the user pressed Enter or Ctrl+B
- root is the test directory path
- files are relative paths (not joined with root yet)
"""
function select_test_files(query::AbstractString, pkg::PackageSpec=current_pkg())
    root, files = get_test_files(pkg)
    # Create a temporary file for ctrl-b output
    # We need to go through a file to avoid problematic ANSI codes produces by fzf when closing.
    tmpfile = tempname()
    # Run fzf to get a relevant file.
    fzf_args = [
        "-m", # Allow multiple choices.
        "--preview", # Preview the given file with bat.
        "$(get_bat_path()) --color=always --style=numbers {-1}",
        "--header",
        "Enter=run files | Ctrl+B=switch to test blocks for selected file(s) | Tab=select multiple files",
        "--scheme=path",
        "--query", # Initial file query.
        query,
        "--bind",
        "ctrl-b:execute-silent(echo __TESTBLOCK_MODE__ > $(tmpfile); echo {+} >> $(tmpfile))+abort",
    ]
    cmd = `$(fzf()) $(fzf_args)`
    output = readlines(
        pipeline(Cmd(cmd; ignorestatus=true, dir=root); stdin=IOBuffer(join(files, '\n')))
    )

    # Check if ctrl-b was pressed by checking the temp file
    if isfile(tmpfile)
        mode = :testblock
        files = readlines(tmpfile)[2:end]  # Skip the marker line
        rm(tmpfile)
    else
        mode = :file
        files = output
    end

    if isempty(files)
        @debug "Could not find any relevant files with query \"$query\"."
        (mode, root, String[])
    else
        (mode, root, files)
    end
end

"""
    get_test_files(pkg::PackageSpec=current_pkg()) -> (String, Vector{String})

Discover and return all Julia test files for a package.

Recursively searches the package's test directory to find all `.jl` files,
returning both the test directory path and the collection of relative file paths.
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

"""
    fzf_testfile(query::AbstractString) -> Nothing

Interactive test file selection and execution workflow.

Combines file selection and execution in a single workflow: uses fzf to select
test files based on the query, then runs all selected files in the test environment.
If ctrl-b is pressed during file selection, switches to testblock selection mode instead.
"""
function fzf_testfile(query::AbstractString)
    pkg = current_pkg()
    mode, root, files = select_test_files(query, pkg)

    if mode == :testblock
        # User pressed ctrl-b, switch to testblock mode
        # Files are already relative paths, just pass them directly
        return fzf_testblock_from_files(INTERFACES, files, "", pkg, root)
    else
        # Normal file execution mode
        # Convert relative paths to absolute paths for file execution
        absolute_files = joinpath.(Ref(root), files)
        return run_test_files(absolute_files, pkg)
    end
end

"""
    run_test_files(files::AbstractVector{<:AbstractString}, pkg::PackageSpec) -> Nothing

Execute a collection of test files in the package test environment.

Runs each provided test file in sequence, handling errors gracefully and updating
the test evaluation state. Each file is wrapped in a testset and executed in isolation.
"""
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

"""
    run_test_file(file::AbstractString, pkg::PackageSpec) -> Any

Execute a single test file in an isolated testset within the package test environment.

Wraps the test file in a testset named after the package and file, handles test
failures gracefully, and updates the global test state for later inspection.
"""
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
            e
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
