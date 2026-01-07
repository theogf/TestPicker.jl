
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

"""
    TestBlockInfo

Metadata container for a test block, including its location and identification information.

Stores essential information about a test block's location within a file and provides
a label for identification and display purposes.
"""
struct TestBlockInfo
    label::String
    file_name::String
    line_start::Int
    line_end::Int
end

label(info::TestBlockInfo) = info.label
file_name(info::TestBlockInfo) = info.file_name

function TestBlockInfo(block::SyntaxBlock, file::AbstractString)
    (; testblock, interface) = block
    label = blocklabel(interface, testblock)
    line_start, _ = JuliaSyntax.source_location(testblock.source, testblock.position)
    block_length = countlines(IOBuffer(JuliaSyntax.sourcetext(testblock)))
    line_end = line_start + block_length - 1
    return TestBlockInfo(label, file, line_start, line_end)
end

"""
    get_testblocks(interfaces::Vector{<:TestBlockInterface}, file::AbstractString) -> Vector{SyntaxBlock}

Parse a Julia file and extract all test blocks with their associated preamble statements.

For each test block found (including nested ones), collects all preceding preamble
statements that should be executed before the test block. Uses the provided interfaces
to determine what constitutes a test block.
"""
function get_testblocks(interfaces::Vector{<:TestBlockInterface}, file::AbstractString)
    root = parseall(SyntaxNode, read(file, String); filename=file)
    return mapreduce(vcat, interfaces) do interface
        syntax_blocks = Vector{SyntaxBlock}()
        get_testblocks!(interface, syntax_blocks, root)
        syntax_blocks
    end
end
function get_testblocks!(
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
            get_testblocks!(interface, syntax_blocks, node, copy(preamble))
        else
            get_testblocks!(interface, syntax_blocks, node, copy(preamble))
            if ispreamble(node)
                push!(preamble, node)
            end
        end
    end
end

"""
    get_matching_files(file_query::AbstractString, testfiles::AbstractVector{<:AbstractString}) -> Vector{String}

Filter test files using fzf's non-interactive filtering based on the given query.

Uses `fzf --filter` to perform fuzzy matching on the provided list of test files,
returning only those that match the query pattern.
"""
function get_matching_files(
    file_query::AbstractString, testfiles::AbstractVector{<:AbstractString}
)
    return readlines(
        pipeline(
            Cmd(`$(fzf()) --filter $(file_query)`; ignorestatus=true);
            stdin=IOBuffer(join(testfiles, '\n')),
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
    info_to_syntax = mapreduce(merge, matched_files) do file
        # Keep track of file name length for padding.
        syntax_blocks = get_testblocks(interfaces, joinpath(root, file))
        Dict(
            map(syntax_blocks) do syntax_block
                TestBlockInfo(syntax_block, file) => syntax_block
            end,
        )
    end
    # We estimate the max length to perform some padding.
    max_label_length = maximum(length ∘ label, keys(info_to_syntax))
    max_filename_length = maximum(length ∘ file_name, keys(info_to_syntax))
    # We create a new mapping with human readable lines for fzf.
    display_to_info = Dict(
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
    if !interactive
        # Non-interactive mode: use fzf --filter to get matching test blocks
        args = ["--filter", testset_query, "-d", "$(separator())", "--nth", "1"]
        cmd = Cmd(`$(fzf()) $(args)`; ignorestatus=true, dir=root)
        return readlines(pipeline(cmd; stdin=IOBuffer(join(keys(tabled_keys), '\n'))))
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
    testblock_list(choices, info_to_syntax, display_to_info, pkg) -> Vector{EvalTest}

Convert user-selected test block choices into executable test objects.

Takes the selected display strings from fzf and converts them into `EvalTest` objects
that can be evaluated. Each test is wrapped in a try-catch block to handle test failures
gracefully and save results.
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
        (; label, file_name, line_start) = blockinfo
        test_info = TestInfo(file_name, label, line_start)
        (; preamble, testblock, interface) = syntax_block
        block_expr = expr_transform(interface, Expr(testblock))
        tried_testset = quote
            try
                $(block_expr)
            catch e
                !(e isa TestSetException) && rethrow()
                TestPicker.save_test_results(e, $(test_info), $(pkg))
            end
        end
        preamble_statements = prepend_preamble_statements(interface, Expr.(preamble))
        ex = Expr(:block, preamble_statements..., tried_testset)
        EvalTest(ex, test_info)
    end
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
    return fzf_testblock_from_files(
        interfaces, matched_files, fuzzy_testset, pkg, root; interactive
    )
end
