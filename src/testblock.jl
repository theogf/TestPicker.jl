
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
    root = parseall(SyntaxNode, read(file, String); filename=file)
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
    preamble::Vector{SyntaxNode}=SyntaxNode[],
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
    file_query::AbstractString, test_files::AbstractVector{<:AbstractString}
)
    return readlines(
        pipeline(
            Cmd(`$(fzf()) --filter $(file_query)`; ignorestatus=true);
            stdin=IOBuffer(join(test_files, '\n')),
        ),
    )
end

"""
    build_info_to_syntax(interfaces, root, matched_files) -> (Dict{TestBlockInfo,SyntaxBlock}, Dict{String,TestBlockInfo})

Parse matched files and build mapping structures for test block selection and display.

Extracts all test blocks from the provided files and creates two mappings:
1. From test block metadata to syntax information
2. From human-readable display strings (for fzf) to test block metadata
"""
function build_info_to_syntax(
    interfaces::Vector{<:TestBlockInterface},
    root::AbstractString,
    matched_files::AbstractVector{<:AbstractString},
)
    isempty(matched_files) &&
        return Dict{TestBlockInfo,SyntaxBlock}(), Dict{String,TestBlockInfo}()
    info_to_syntax = mapreduce(merge, matched_files) do file
        # Keep track of file name length for padding.
        syntax_blocks = get_syntax_blocks(interfaces, joinpath(root, file))
        Dict{TestBlockInfo,SyntaxBlock}(
            map(syntax_blocks) do syntax_block
                TestBlockInfo(syntax_block, file) => syntax_block
            end,
        )
    end
    # We estimate the max length to perform some padding.
    max_label_length = maximum(length ∘ label, keys(info_to_syntax))
    max_filename_length = maximum(length ∘ file_name, keys(info_to_syntax))
    # We create a new mapping with human readable lines for fzf.
    display_to_info = Dict{String,TestBlockInfo}(
        map(collect(keys(info_to_syntax))) do (; label, file_name, line_start, line_end)
            visible_text = "$(rpad(label, max_label_length + 2)) | $(lpad(file_name,  max_filename_length + 2)):$(line_start)-$(line_end)"
            join([visible_text, file_name, line_start, line_end], separator())
        end .=> keys(info_to_syntax),
    )
    return info_to_syntax, display_to_info
end

"""
    pick_testblock(tabled_keys, testset_query, root; interactive::Bool=true) -> Vector{String}

Select test blocks to execute based on a fuzzy search query.

If `interactive=true` (default), launches fzf with a preview window (using bat) that allows
users to select one or more test blocks from the filtered list. The preview shows the actual
test code with syntax highlighting.

If `interactive=false`, uses fzf's filter mode to non-interactively return all matching test blocks.
"""
function pick_testblock(
    tabled_keys::Dict{String,TestBlockInfo},
    testset_query::AbstractString,
    root::AbstractString;
    interactive::Bool=true,
)
    args = ["--filter", testset_query, "-d", "$(separator())", "--nth", "1"]
    cmd = Cmd(`$(fzf()) $(args)`; ignorestatus=true, dir=root)
    # We do a dry lookup to see what results we get.
    filtered_list = readlines(pipeline(cmd; stdin=IOBuffer(join(keys(tabled_keys), '\n'))))
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
    return readlines(pipeline(cmd; stdin=IOBuffer(join(keys(tabled_keys), '\n'))))
end

"""
    hash_file(path::AbstractString) -> UInt64

Hash the content of a file, used to detect that a test file was modified between
the moment a test block was picked and the moment it is rerun.
"""
hash_file(path::AbstractString) = hash(read(path))

"""
    build_evaltest(blockinfo::TestBlockInfo, syntax_block::SyntaxBlock, pkg::PackageSpec) -> EvalTest

Build an executable [`EvalTest`](@ref) from a parsed test block.

The test block is wrapped in a try-catch block to handle test failures gracefully and
save results, and its preamble statements are prepended. The current content hash of the
source file is recorded so that reruns can detect a stale expression.
"""
function build_evaltest(
    blockinfo::TestBlockInfo, syntax_block::SyntaxBlock, pkg::PackageSpec
)
    (; label, file_name, line_start) = blockinfo
    test_info = TestInfo(file_name, label, line_start)
    (; preamble, testblock, interface) = syntax_block
    root = get_test_dir_from_pkg(pkg)
    block_expr = expr_transform(interface, Expr(testblock), blockinfo, root)
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
    return EvalTest(ex, test_info, hash_file(joinpath(root, file_name)))
end

"""
    testblock_list(choices, info_to_syntax, display_to_info, pkg) -> Vector{EvalTest}

Convert user-selected test block choices into executable test objects.

Takes the selected display strings from fzf and converts them into `EvalTest` objects
that can be evaluated (see [`build_evaltest`](@ref)).
"""
function testblock_list(
    choices::Vector{<:AbstractString},
    info_to_syntax::Dict{TestBlockInfo,SyntaxBlock},
    display_to_info::Dict{String,TestBlockInfo},
    pkg::PackageSpec,
)::Vector{EvalTest}
    map(choices) do choice
        blockinfo = display_to_info[choice]
        syntax_block = info_to_syntax[blockinfo]
        build_evaltest(blockinfo, syntax_block, pkg)
    end
end

"""
    refresh_evaltest(interfaces, test::EvalTest, pkg::PackageSpec) -> EvalTest

Return an up-to-date version of `test`, rebuilding its expression if the source file changed.

Rerunning a test block evaluates a previously built expression, which would silently ignore
any edit made to the test file in the meantime. This function detects such edits by comparing
the stored file hash with the current one. If the file changed, it is re-parsed and the test
block with the same label is looked up again (when several blocks share the label, the one
closest to the original line wins) and rebuilt, picking up both the new block content and any
modified preamble.

The original `test` is returned unchanged when it does not track a source file
(`filehash === nothing`, e.g. whole-file runs that `include` the file afresh), when the file
content is identical, or — with a warning — when the file or the block cannot be found anymore.
"""
function refresh_evaltest(
    interfaces::Vector{<:TestBlockInterface}, test::EvalTest, pkg::PackageSpec
)
    isnothing(test.filehash) && return test
    (; filename, label, line) = test.info
    root = get_test_dir_from_pkg(pkg)
    path = joinpath(root, filename)
    if !isfile(path)
        @warn "Test file $(filename) does not exist anymore, rerunning the previously evaluated version of $(label)."
        return test
    end
    hash_file(path) == test.filehash && return test
    matches = [
        (TestBlockInfo(syntax_block, filename), syntax_block) for
        syntax_block in get_syntax_blocks(interfaces, path)
    ]
    filter!(((blockinfo, _),) -> blockinfo.label == label, matches)
    if isempty(matches)
        @warn "Could not find test block $(label) in the modified file $(filename), rerunning the previously evaluated version."
        return test
    end
    blockinfo, syntax_block = argmin(
        ((blockinfo, _),) -> abs(blockinfo.line_start - line), matches
    )
    @info "$(filename) was modified, rerunning the updated version of test block $(label)."
    return build_evaltest(blockinfo, syntax_block, pkg)
end

"""
    fzf_testblock_from_files(interfaces, matched_files, fuzzy_testset, pkg, root; interactive::Bool=true) -> Nothing

Test block selection and execution from a list of matched files.

If `interactive=true` (default), presents an fzf interface to select specific test blocks
from those files based on `fuzzy_testset` query.

If `interactive=false`, uses fzf's filter mode to non-interactively select and run all
matching test blocks.
"""
function fzf_testblock_from_files(
    interfaces::Vector{<:TestBlockInterface},
    matched_files::AbstractVector{<:AbstractString},
    fuzzy_testset::AbstractString,
    pkg::PackageSpec,
    root::AbstractString;
    interactive::Bool=true,
)
    # We create  the collection of testsets based on the list of files.
    info_to_syntax, display_to_info = build_info_to_syntax(interfaces, root, matched_files)

    choices = pick_testblock(display_to_info, fuzzy_testset, root; interactive)
    if !isempty(choices)
        tests = testblock_list(choices, info_to_syntax, display_to_info, pkg)
        clean_results_file(pkg)
        LATEST_EVAL[] = tests
        map(tests) do test
            result = eval_in_module(test, pkg)
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
    pkg = current_pkg()
    root, testfiles = get_testfiles(pkg)
    # We fetch all valid test files.
    matched_files = get_matching_files(fuzzy_file, testfiles)
    fzf_testblock_from_files(
        interfaces, matched_files, fuzzy_testset, pkg, root; interactive
    )
end
