"""
    TestFile

One test file of one package, as offered by the pickers.

`name` is the path of the file relative to `root`, the test directory of `pkg`. That
relative path is what the rest of TestPicker records ([`TestInfo`](@ref),
[`TestBlockInfo`](@ref), the results file), so a file is identified the same way whether it
was picked from a lone package or from a package of a workspace.

`label` is how the file is shown in, and matched by, the pickers: `name` on its own, or
`name` prefixed by the package it belongs to when several packages are in play, so that the
`runtests.jl` of two packages of a workspace stay distinguishable and a query can narrow
down to a single package.
"""
struct TestFile
    pkg::PackageSpec
    root::String
    name::String
    label::String
end

function TestFile(pkg::PackageSpec, root::AbstractString, name::AbstractString)
    return TestFile(pkg, root, name, name)
end

Base.abspath(file::TestFile) = joinpath(file.root, file.name)

"""
    common_root(files::AbstractVector{TestFile}) -> String

Deepest directory containing every file of `files`.

Used as the working directory of the pickers, so that they preview paths relative to it:
that is the test directory itself for a lone package, and the directory holding the
workspace when the files come from several packages.
"""
function common_root(files::AbstractVector{TestFile})
    isempty(files) && return pwd()
    common = splitpath(abspath(first(files).root))
    for file in files
        parts = splitpath(abspath(file.root))
        n = 0
        while n < min(length(common), length(parts)) && common[n + 1] == parts[n + 1]
            n += 1
        end
        common = common[1:n]
    end
    # Paths with nothing in common at all (different drives on Windows) have no root.
    return isempty(common) ? pwd() : joinpath(common...)
end

"""
    fzf_record(file::TestFile, root::AbstractString) -> String

The `separator()`-delimited record the file picker reads on its stdin: the label to display
and match on, and the path to preview, relative to `root`, the picker's working directory.
"""
function fzf_record(file::TestFile, root::AbstractString)
    return join([file.label, relpath(abspath(file), root)], separator())
end

"""
    select_testfiles(query::AbstractString, pkgs::AbstractVector{PackageSpec}=current_pkgs(); interactive::Bool=true) -> (Symbol, Vector{TestFile})

Select test files using fzf based on a fuzzy search query.

If `interactive=true` (default), presents an fzf interface showing all test files of `pkgs`,
with syntax-highlighted preview using bat. Users can select multiple files and the query
pre-filters the results.

If `interactive=false`, uses fzf's filter mode to non-interactively return all matching files.

Returns a tuple of (mode, files) where mode is either `:file` or `:testblock` depending on
whether the user pressed Enter or Ctrl+B (interactive mode only, always `:file` in
non-interactive mode).
"""
function select_testfiles(
    query::AbstractString,
    pkgs::AbstractVector{PackageSpec}=current_pkgs();
    interactive::Bool=true,
)
    files = get_testfiles(pkgs)
    # We do a dry lookup to see what results we get.
    matched_files = get_matching_files(query, files)
    if !interactive || isone(length(matched_files))
        # Non-interactive mode: use fzf --filter to get matching files
        if isempty(matched_files)
            @debug "Could not find any relevant files with query \"$query\"."
            return (:file, TestFile[])
        else
            return (:file, matched_files)
        end
    end

    # Interactive mode (original behavior)
    root = common_root(files)
    # The records feed the picker in order, the mappings read its answer back: `fzf` echoes
    # the records it was given on Enter, and the `ctrl-b` binding prints their first field.
    records = [fzf_record(file, root) for file in files]
    by_record = Dict(records .=> files)
    by_label = Dict(file.label => file for file in files)
    # Create a temporary file for ctrl-b output
    # We need to go through a file to avoid problematic ANSI codes produces by fzf when closing.
    tmpfile = tempname()
    # Run fzf to get a relevant file.
    fzf_args = [
        "-m", # Allow multiple choices.
        "-d", # The record holds the path to preview next to the visible label.
        "$(separator())",
        "--nth", # Limit search scope to the visible label.
        "1",
        "--with-nth", # Only show the visible label.
        "{1}",
        "--preview", # Preview the given file with bat.
        "$(get_bat_path()) --color=always --style=numbers {2}",
        "--header",
        "Enter=run files | Ctrl+B=switch to test blocks for selected file(s) | Tab=select multiple files",
        "--scheme=path",
        "--query", # Initial file query.
        query,
        "--bind",
        "ctrl-b:execute-silent(printf '%s\\n' {+1} > $(tmpfile))+accept",
    ]
    cmd = `$(fzf()) $(fzf_args)`
    output = readlines(
        pipeline(Cmd(cmd; ignorestatus=true, dir=root); stdin=IOBuffer(join(records, '\n')))
    )

    # Check if ctrl-b was pressed by checking the temp file
    if isfile(tmpfile)
        mode = :testblock
        picked = [
            by_label[label] for label in readlines(tmpfile) if haskey(by_label, label)
        ]
        rm(tmpfile)
    else
        mode = :file
        picked = [by_record[record] for record in output if haskey(by_record, record)]
    end

    if isempty(picked)
        @debug "Could not find any relevant files with query \"$query\"."
        return (mode, TestFile[])
    end
    return (mode, picked)
end

"""
    get_testfiles(pkg::PackageSpec=current_pkg()) -> (String, Vector{String})
    get_testfiles(pkgs::AbstractVector{PackageSpec}) -> Vector{TestFile}

Discover and return all Julia test files for a package, or for a collection of packages.

Recursively searches the package's test directory to find all `.jl` files, returning both
the test directory path and the collection of relative file paths. Given several packages,
e.g. the packages of a workspace, returns [`TestFile`](@ref)s instead, each labelled with
the package it belongs to.
"""
function get_testfiles(pkg::PackageSpec=current_pkg())
    test_dir = get_test_dir_from_pkg(pkg)
    # Recursively get a list of julia files.
    return test_dir,
    mapreduce(vcat, walkdir(test_dir)) do (root, _, files)
        relpath.(filter(endswith(".jl"), joinpath.(Ref(root), files)), Ref(test_dir))
    end
end

function get_testfiles(pkgs::AbstractVector{PackageSpec})
    # A lone package needs no qualification, its file names are unambiguous already.
    qualify = !isone(length(pkgs))
    return mapreduce(vcat, pkgs; init=TestFile[]) do pkg
        root, names = get_testfiles(pkg)
        map(names) do name
            TestFile(pkg, root, name, qualify ? joinpath(pkg.name, name) : name)
        end
    end
end

"""
    get_test_dir_from_pkg(pkg::PackageSpec=current_pkg()) -> String

Locate the test directory of `pkg`.

A `pkg` that already points at a source tree, e.g. a package of a workspace, is trusted
as-is: its test directory is right there, no need to resolve it against the active
environment, which may well not have it as a dependency.
"""
function get_test_dir_from_pkg(pkg::PackageSpec=current_pkg())
    if !isnothing(pkg.path)
        test_dir = joinpath(pkg.path, "test")
        isdir(test_dir) && return test_dir
    end
    ctx = Context()
    isinstalled!(ctx, pkg) || throw(ArgumentError("$pkg not installed 👻"))
    test_dir = get_test_dir(ctx, pkg)
    isdir(test_dir) || error(
        "the test directory $(test_dir) does not exist, you need to activate your package environment first",
    )
    return test_dir
end

"""
    fzf_testfile(query::AbstractString; interactive::Bool=true) -> Nothing

Test file selection and execution workflow.

If `interactive=true` (default), uses fzf to interactively select test files based on the query,
then runs all selected files in the test environment. If ctrl-b is pressed during file selection,
switches to testblock selection mode instead.

If `interactive=false`, uses fzf's filter mode to non-interactively select and run all matching
test files based on the query.
"""
function fzf_testfile(query::AbstractString; interactive::Bool=true)
    mode, files = select_testfiles(query, current_pkgs(); interactive)

    if mode == :testblock
        # User pressed ctrl-b, switch to testblock mode (only possible in interactive mode)
        return fzf_testblock_from_files(INTERFACES, files, "")
    else
        # Normal file execution mode
        return run_testfiles(files)
    end
end

"""
File to evaluate was empty.
"""
struct EmptyFile end

"""
Provided file could not be found.
"""
struct MissingFileException <: Exception
    file::String
end

function Base.showerror(io::IO, (; file)::MissingFileException)
    return println(
        io,
        "File $(file) could not be found, this sounds like a bug, please report it on https://github.com/theogf/TestPicker.jl/issues/new.",
    )
end

"""
    run_testfiles(files::AbstractVector{TestFile}) -> Nothing

Execute a collection of test files, each in the test environment of the package it belongs to.

Runs each provided test file in sequence, handling errors gracefully and updating
the test evaluation state. Each file is wrapped in a testset and executed in isolation.
"""
function run_testfiles(files::AbstractVector{TestFile})
    # We return early to not empty the LATEST_EVAL
    isempty(files) && return nothing
    # Reset the latest eval data.
    LATEST_EVAL[] = EvalTest[]
    # A selection can span several packages of a workspace, each with its own results file.
    foreach(clean_results_file, unique_pkgs(file.pkg for file in files))
    map(files) do file
        path = abspath(file)
        if isempty(file.name)
            EmptyFile()
        elseif !isfile(path)
            @error "File $(path) could not be found, this sounds like a bug, please report it on https://github.com/theogf/TestPicker.jl/issues/new."
            MissingFileException(path)
        else
            run_testfile(file)
        end
    end
end

"""
    run_testfile(file::TestFile) -> EvalResult

Execute a single test file in an isolated testset within the test environment of its package.

Wraps the test file in a testset named after the package and file, handles test
failures gracefully, and updates the global test state for later inspection.
"""
function run_testfile(file::TestFile)
    (; pkg, name) = file
    testset_name = "$(pkg.name) - $(name)"
    test_info = TestInfo(name, "", 0)
    path = abspath(file)
    ex = quote
        @testset TestPickerTestSet $testset_name begin
            include($path)
        end
    end
    test = EvalTest(ex, test_info, pkg)
    if !isnothing(LATEST_EVAL[])
        push!(LATEST_EVAL[], test)
    else
        LATEST_EVAL[] = [test]
    end
    result = eval_in_module(test)
    # result is nothing when the testset is a success.
    return EvalResult(isnothing(result), test_info, result)
end
