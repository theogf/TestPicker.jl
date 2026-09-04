
"""
    ispreamble(node::SyntaxNode) -> Bool

Check if a statement qualifies as a preamble that should be executed before test blocks.

A preamble statement is any statement that sets up the testing environment, such as:
- Function calls (`:call`)
- Import/using statements (`:using`, `:import`)
- Variable assignments (`:=`)
- Macro calls (`:macrocall`)
- Function definitions (`:function`)
"""
function ispreamble(node::SyntaxNode)
    ex = Expr(node)
    Meta.isexpr(ex, :call) && return true
    Meta.isexpr(ex, :using) && return true
    Meta.isexpr(ex, :import) && return true
    Meta.isexpr(ex, :(=)) && return true
    Meta.isexpr(ex, :macrocall) && return true
    Meta.isexpr(ex, :function) && return true
    return false
end

"""
    SyntaxBlock

A container for a test block and its associated preamble statements.

Contains all the necessary components to execute a test block, including any setup
code that needs to run beforehand. Can be easily converted into an evaluatable expression.
"""
struct SyntaxBlock
    preamble::Vector{SyntaxNode}
    testblock::SyntaxNode
    interface::TestBlockInterface
end

function TestBlockInfo(block::SyntaxBlock, file::AbstractString)
    (; testblock, interface) = block
    label = blocklabel(interface, testblock)
    line_start, _ = JuliaSyntax.source_location(testblock.source, testblock.position)
    block_length = countlines(IOBuffer(JuliaSyntax.sourcetext(testblock)))
    line_end = line_start + block_length - 1
    return TestBlockInfo(label, file, line_start, line_end)
end

"""
    get_syntax_blocks(interfaces::Vector{<:TestBlockInterface}, file::AbstractString) -> Vector{SyntaxBlock}

Parse a Julia file and extract all test blocks with their associated preamble statements.

For each test block found (including nested ones), collects all preceding preamble
statements that should be executed before the test block. Uses the provided interfaces
to determine what constitutes a test block.

# Arguments
- `interfaces::Vector{<:TestBlockInterface}`: Collection of test block interfaces to use for parsing
- `file::AbstractString`: Path to the Julia file to parse

# Returns
- `Vector{SyntaxBlock}`: Collection of parsed test blocks with their preambles
"""
function get_syntax_blocks(interfaces::Vector{<:TestBlockInterface}, file::AbstractString)
    root = parseall(SyntaxNode, read(file, String); filename = file)
    return mapreduce(vcat, interfaces) do interface
        syntax_blocks = Vector{SyntaxBlock}()
        get_syntax_blocks!(interface, syntax_blocks, root)
        syntax_blocks
    end
end
function get_syntax_blocks!(
    interface::TestBlockInterface,
    syntax_blocks::Vector{SyntaxBlock},
    node::SyntaxNode,
    preamble::Vector{SyntaxNode} = SyntaxNode[],
)
    nodes = JuliaSyntax.children(node)
    isnothing(nodes) && return nothing
    for node in nodes
        if istestblock(interface, node)
            push!(syntax_blocks, SyntaxBlock(copy(preamble), node, interface))
            get_syntax_blocks!(interface, syntax_blocks, node, copy(preamble))
        else
            get_syntax_blocks!(interface, syntax_blocks, node, copy(preamble))
            if ispreamble(node)
                push!(preamble, node)
            end
        end
    end
end

"""
    get_matching_files(file_query::AbstractString, test_files::AbstractVector{<:AbstractString}) -> Vector{String}

Filter test files using fzf's non-interactive filtering based on the given query.

Uses `fzf --filter` to perform fuzzy matching on the provided list of test files,
returning only those that match the query pattern.

# Arguments
- `file_query::AbstractString`: Fuzzy search pattern to match against file names
- `test_files::AbstractVector{<:AbstractString}`: List of test file paths to filter

# Returns
- `Vector{String}`: List of file paths that match the query

# Examples
```julia
files = ["test/test_math.jl", "test/test_string.jl", "test/integration.jl"]
get_matching_files("math", files)  # Returns ["test/test_math.jl"]
```
"""
function get_matching_files(
    file_query::AbstractString,
    test_files::AbstractVector{<:AbstractString},
)
    return readlines(
        pipeline(
            Cmd(`$(fzf()) --filter $(file_query)`; ignorestatus = true);
            stdin = IOBuffer(join(test_files, '\n')),
        ),
    )
end

"""
    get_matching_files(file_query::AbstractString, files::AbstractVector{TestFile}) -> Vector{TestFile}

Filter [`TestFile`](@ref)s on their label, i.e. on the very text the picker shows, so that
in a workspace a query can name the package it is after (`PkgA/runtests`) as well as the
file.
"""
function get_matching_files(file_query::AbstractString, files::AbstractVector{TestFile})
    by_label = Dict(file.label => file for file in files)
    labels = get_matching_files(file_query, [file.label for file in files])
    return [by_label[label] for label in labels]
end

"""
    TestBlockEntry

One test block the picker can offer: the [`TestFile`](@ref) it was found in, its metadata
and the parsed block itself.
"""
struct TestBlockEntry
    file::TestFile
    info::TestBlockInfo
    block::SyntaxBlock
end

"""
    build_testblocks(interfaces, files, root=common_root(files)) -> Dict{String,TestBlockEntry}

Parse `files` and build the records the test block picker works with.

Each test block found becomes one `separator()`-delimited record, mapped to the
[`TestBlockEntry`](@ref) it stands for: the human readable text `fzf` displays and matches
on, then the path to preview relative to `root` (the picker's working directory) and the
line range of the block. Keying on the record is what keeps two blocks apart when they only
differ by the package they come from, as happens in a workspace.
"""
function build_testblocks(
    interfaces::Vector{<:TestBlockInterface},
    files::AbstractVector{TestFile},
    root::AbstractString=common_root(files),
)
    entries = mapreduce(vcat, files; init=TestBlockEntry[]) do file
        map(get_syntax_blocks(interfaces, abspath(file))) do syntax_block
            TestBlockEntry(file, TestBlockInfo(syntax_block, file.name), syntax_block)
        end
    end
    # None of the matched files contained any recognized test block.
    isempty(entries) && return Dict{String,TestBlockEntry}()
    # We estimate the max length to perform some padding.
    max_label_length = maximum(entry -> length(entry.info.label), entries)
    max_filename_length = maximum(entry -> length(entry.file.label), entries)
    return Dict(
        map(entries) do entry
            fzf_record(entry, root, max_label_length, max_filename_length) => entry
        end,
    )
end

"""
    fzf_record(entry::TestBlockEntry, root, max_label_length, max_filename_length) -> String

The `separator()`-delimited record the test block picker reads on its stdin: the visible
text, then the path to preview relative to `root` and the line range to preview.
"""
function fzf_record(
    entry::TestBlockEntry,
    root::AbstractString,
    max_label_length::Int,
    max_filename_length::Int,
)
    (; line_start, line_end) = entry.info
    visible_text = "$(rpad(entry.info.label, max_label_length + 2)) | $(lpad(entry.file.label,  max_filename_length + 2)):$(line_start)-$(line_end)"
    path = relpath(abspath(entry.file), root)
    return join([visible_text, path, line_start, line_end], separator())
end

"""
    pick_testblock(entries, testset_query, root; interactive::Bool=true) -> Vector{String}

Select test blocks to execute based on a fuzzy search query.

If `interactive=true` (default), launches fzf with a preview window (using bat) that allows
users to select one or more test blocks from the filtered list. The preview shows the actual
test code with syntax highlighting.

If `interactive=false`, uses fzf's filter mode to non-interactively return all matching test blocks.
"""
function pick_testblock(
    entries::Dict{String,TestBlockEntry},
    testset_query::AbstractString,
    root::AbstractString;
    interactive::Bool=true,
)
    args = ["--filter", testset_query, "-d", "$(separator())", "--nth", "1"]
    cmd = Cmd(`$(fzf()) $(args)`; ignorestatus=true, dir=root)
    # We do a dry lookup to see what results we get.
    filtered_list = readlines(pipeline(cmd; stdin=IOBuffer(join(keys(entries), '\n'))))
    if !interactive || isone(length(filtered_list))
        # Non-interactive mode: use fzf --filter to get matching test blocks
        args = ["--filter", testset_query, "-d", "$(separator())", "--nth", "1"]
        cmd = Cmd(`$(fzf()) $(args)`; ignorestatus=true, dir=root)
        return filtered_list
    end

    # Interactive mode (original behavior)
    bat_preview = "$(get_bat_path()) --color always --line-range {3}:{4} {2}"
    # Leave the user the choice of a testset.
    args = [
        "-m", # Multiple choice
        "-d", #
        "$(separator())",
        "--nth", # Limit search scope to visible text.
        "1",
        "--with-nth", # Only show visible text.
        "{1}",
        "--preview", # Preview show the relevant testset.
        "$(bat_preview)",
        "--header",
        "Selecting testset from filtered test files",
        "--query", # Initial query on the testset names.
        testset_query,
    ]
    cmd = Cmd(`$(fzf()) $(args)`; ignorestatus=true, dir=root)
    return readlines(pipeline(cmd; stdin=IOBuffer(join(keys(entries), '\n'))))
end

"""
    build_eval_test(entry::TestBlockEntry) -> EvalTest

Build an executable [`EvalTest`](@ref) from a located test block.

Wraps the block in a `TestPickerTestSet`, prepends any preamble required by its
interface, carries over the package the block belongs to (so that a rerun still knows which
test environment to activate) and records a CRC32c checksum of the source file's current
contents (used by [`refresh_stale_test`](@ref) to detect edits before a rerun).
"""
function build_eval_test((; file, info, block)::TestBlockEntry)::EvalTest
    (; label, file_name, line_start) = info
    (; pkg, root) = file
    test_info = TestInfo(file_name, label, line_start)
    (; preamble, testblock, interface) = block
    block_expr = expr_transform(interface, Expr(testblock), info, root)
    tried_testset = quote
        try
            @testset TestPickerTestSet $(label) begin
                $(block_expr)
            end
        catch e
            !(e isa Union{TestSetException,TestPicker.TestPickerTestSetException}) &&
                rethrow()
            TestPicker.save_test_results(e, $(test_info), $(pkg))
        end
    end
    preamble_statements = prepend_preamble_statements(interface, Expr.(preamble))
    ex = Expr(:block, preamble_statements..., tried_testset)
    content_hash = crc32c(read(abspath(file)))
    return EvalTest(ex, test_info, pkg, content_hash)
end

"""
    testblock_list(choices, entries) -> Vector{EvalTest}

Convert user-selected test block choices into executable test objects.

Takes the records `fzf` echoed back and converts the [`TestBlockEntry`](@ref) each of them
stands for into an `EvalTest` that can be evaluated. Each test is wrapped in a try-catch
block to handle test failures gracefully and save results.
"""
function testblock_list(
    choices::Vector{<:AbstractString}, entries::Dict{String,TestBlockEntry}
)::Vector{EvalTest}
    return map(choice -> build_eval_test(entries[choice]), choices)
end

"""
    refresh_stale_test(test::EvalTest) -> Union{Nothing,EvalTest}

Re-locate a test block's source before rerunning it, if the file changed since capture.

`test> -` normally replays the exact expression captured when the block was selected.
If the source file was edited since then, that expression no longer reflects what's on
disk. This compares a CRC32c checksum of the file's current contents against the one
recorded on `test` (a content hash, rather than the modification time, so a real edit is
never missed due to coarse mtime resolution or a save that happens to restore the
original mtime). If the checksum changed, the whole file is re-parsed from scratch via
[`build_testblocks`](@ref) — the same routine used for the original selection, so
every block's preamble is recomputed exactly as it would be for a fresh pick — and the
block whose label aligns with `test`'s is looked up in the result.

Whole-file tests (empty label, from `test> <file>`) are returned unchanged: they
`include` the file, so they already see edits on rerun. If the file can no longer be
found, if no block with a matching label exists anymore (renamed or removed), or if the
label is now ambiguous (matches more than one block), there is no reliable way to know
what to rerun: a warning is emitted and `nothing` is returned, so the stale test is
dropped rather than silently re-running outdated code.
"""
function refresh_stale_test(test::EvalTest)::Union{Nothing,EvalTest}
    (; info, pkg) = test
    isempty(info.label) && return test
    root = get_test_dir_from_pkg(pkg)
    file = TestFile(pkg, root, info.filename)
    path = abspath(file)
    if !isfile(path)
        @warn "File $(info.filename) could not be found anymore; dropping test block \"$(info.label)\" from the rerun."
        return nothing
    end
    current_hash = crc32c(read(path))
    current_hash == test.content_hash && return test

    @info "File $(info.filename) was modified since test block \"$(info.label)\" was captured; refetching it from scratch."
    entries = build_testblocks(INTERFACES, [file])
    matches = filter(((_, entry),) -> entry.info.label == info.label, entries)
    if isempty(matches)
        @warn "Test block \"$(info.label)\" could not be found anymore in $(info.filename); it may have been renamed or removed. Dropping it from the rerun."
        return nothing
    elseif length(matches) > 1
        @warn "Test block \"$(info.label)\" now matches $(length(matches)) blocks in $(info.filename); cannot tell which one to rerun. Dropping it from the rerun."
        return nothing
    end
    return build_eval_test(only(values(matches)))
end

"""
    fzf_testblock_from_files(interfaces, matched_files, fuzzy_testset; interactive::Bool=true) -> Nothing

Test block selection and execution from a list of matched files.

If `interactive=true` (default), presents an fzf interface to select specific test blocks
from those files based on `fuzzy_testset` query.

If `interactive=false`, uses fzf's filter mode to non-interactively select and run all
matching test blocks.

The files may well come from several packages of a workspace, in which case each selected
block is run in the test environment of the package it belongs to.
"""
function fzf_testblock_from_files(
    interfaces::Vector{<:TestBlockInterface},
    matched_files::AbstractVector{TestFile},
    fuzzy_testset::AbstractString;
    interactive::Bool=true,
)
    # We create  the collection of testsets based on the list of files.
    root = common_root(matched_files)
    entries = build_testblocks(interfaces, matched_files, root)

    choices = pick_testblock(entries, fuzzy_testset, root; interactive)
    if !isempty(choices)
        tests = testblock_list(choices, entries)
        foreach(clean_results_file, unique_pkgs(test.pkg for test in tests))
        LATEST_EVAL[] = tests
        map(tests) do test
            result = eval_in_module(test)
            EvalResult(isnothing(result), test.info, result)
        end
    end
end

"""
    fzf_testblock(interfaces, fuzzy_file, fuzzy_testset; interactive::Bool=true) -> Nothing

Test block selection and execution workflow using fzf.

Provides a two-stage fuzzy finding process:
1. Filter test files based on `fuzzy_file` query
2. Select specific test blocks from filtered files based on `fuzzy_testset` query

If `interactive=true` (default), uses fzf's interactive mode for selecting test blocks.
If `interactive=false`, uses fzf's filter mode to non-interactively select and run all matching test blocks.
"""
function fzf_testblock(
    interfaces::Vector{<:TestBlockInterface},
    fuzzy_file::AbstractString,
    fuzzy_testset::AbstractString;
    interactive::Bool=true,
)
    # We fetch all valid test files, of every package of the workspace if there is one.
    testfiles = get_testfiles(current_pkgs())
    matched_files = get_matching_files(fuzzy_file, testfiles)
    fzf_testblock_from_files(interfaces, matched_files, fuzzy_testset; interactive)
end
