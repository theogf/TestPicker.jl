"""
    select_test_files(query::AbstractString, pkg::PackageSpec=current_pkg()) -> Vector{String}

Interactively select test files using fzf based on a fuzzy search query.

Presents an fzf interface showing all test files for the package, with syntax-highlighted
preview using bat. Users can select multiple files and the query pre-filters the results.

# Arguments
- `query::AbstractString`: Initial fuzzy search pattern for filtering test files
- `pkg::PackageSpec`: Package specification (defaults to current package)

# Returns
- `Vector{String}`: Full paths to selected test files, empty if no selection made

# Features
- Multi-selection enabled (can choose multiple test files)
- Syntax-highlighted preview of file contents
- Pre-filtered results based on initial query
- Returns full absolute paths ready for execution

# Examples
```julia
# Select test files matching "math"
files = select_test_files("math")

# Select from specific package
pkg = PackageSpec(name="MyPackage")
files = select_test_files("integration", pkg)
```

# See also
[`get_test_files`](@ref), [`fzf_testfile`](@ref)
"""
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
    get_test_files(pkg::PackageSpec=current_pkg()) -> (String, Vector{String})

Discover and return all Julia test files for a package.

Recursively searches the package's test directory to find all `.jl` files,
returning both the test directory path and the collection of relative file paths.

# Arguments
- `pkg::PackageSpec`: Package specification (defaults to current package)

# Returns
- `Tuple{String, Vector{String}}`: 
  - First element: Absolute path to the test directory
  - Second element: Vector of test file paths relative to test directory

# Notes
- Only includes files with `.jl` extension
- Searches recursively through subdirectories
- File paths are normalized and relative to test directory root

# Examples
```julia
test_dir, files = get_test_files()
# test_dir: "/path/to/MyPackage/test"
# files: ["runtests.jl", "subdir/test_math.jl", "test_utils.jl"]
```
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

# Arguments
- `query::AbstractString`: Initial search pattern for filtering test files

# Process
1. Get current package context
2. Present fzf interface for file selection
3. Execute all selected test files
4. Handle results and error reporting

# Side Effects
- Updates `LATEST_EVAL[]` with executed tests
- Clears and populates results file with any failures/errors
- May modify test environment state

# Examples
```julia
# Run tests matching "integration"
fzf_testfile("integration")

# Run all test files (empty query shows all)
fzf_testfile("")
```

# See also
[`select_test_files`](@ref), [`run_test_files`](@ref)
"""
function fzf_testfile(query::AbstractString)
    pkg = current_pkg()
    files = select_test_files(query, pkg)
    return run_test_files(files, pkg)
end

"""
    run_test_files(files::AbstractVector{<:AbstractString}, pkg::PackageSpec) -> Nothing

Execute a collection of test files in the package test environment.

Runs each provided test file in sequence, handling errors gracefully and updating
the test evaluation state. Each file is wrapped in a testset and executed in isolation.

# Arguments
- `files::AbstractVector{<:AbstractString}`: Full paths to test files to execute
- `pkg::PackageSpec`: Package specification for test environment context

# Behavior
- Returns early if no files provided (preserves existing `LATEST_EVAL` state)
- Resets `LATEST_EVAL[]` to empty array for new test run
- Clears results file before execution
- Validates file existence before attempting execution
- Continues execution even if individual files fail

# Side Effects
- Modifies `LATEST_EVAL[]` global state
- Clears and populates results file
- May output error messages for missing files

# Error Handling
- Validates file paths before execution
- Reports missing files as errors with bug report guidance
- Individual file failures don't stop batch execution

# See also
[`run_test_file`](@ref), [`select_test_files`](@ref), [`clean_results_file`](@ref)
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

# Arguments
- `file::AbstractString`: Path to the test file to execute
- `pkg::PackageSpec`: Package specification for environment and naming

# Process
1. Creates a testset named "{package} - {file}"
2. Includes the test file within the testset
3. Catches and saves any test failures/errors
4. Updates `LATEST_EVAL[]` with the test execution
5. Evaluates in isolated module environment

# Test Structure
The file is executed within this structure:
```julia
@testset "PackageName - filepath" begin
    include("filepath")
end
```

# Side Effects
- Updates or initializes `LATEST_EVAL[]` global state
- May save test results to results file on failures
- Executes file in test environment context

# Error Handling
- Test failures are caught and saved rather than propagated
- Non-test errors are re-thrown
- File-level errors are properly contextualized

# See also
[`eval_in_module`](@ref), [`save_test_results`](@ref), [`EvalTest`](@ref)
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
