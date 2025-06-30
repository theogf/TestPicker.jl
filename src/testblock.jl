
"""
    ispreamble(node::SyntaxNode) -> Bool

Check if a statement qualifies as a preamble that should be executed before test blocks.

A preamble statement is any statement that sets up the testing environment, such as:
- Function calls (`:call`)
- Import/using statements (`:using`, `:import`)  
- Variable assignments (`:=`)
- Macro calls (`:macrocall`)
- Function definitions (`:function`)

# Arguments
- `node::SyntaxNode`: The syntax node to check

# Returns
- `Bool`: `true` if the node represents a preamble statement, `false` otherwise

# Examples
```julia
# These would return true:
using Test
import MyModule
x = 10
@testset "setup" begin end
function helper() end
```
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

# Fields
- `preamble::Vector{SyntaxNode}`: Collection of preamble statements (imports, assignments, etc.)
- `testblock::SyntaxNode`: The actual test block node (e.g., `@testset`)
- `interface::TestBlockInterface`: The interface implementation used to parse this block
"""
struct SyntaxBlock
    preamble::Vector{SyntaxNode}
    testblock::SyntaxNode
    interface::TestBlockInterface
end

"""
    get_testblocks(interfaces::Vector{<:TestBlockInterface}, file::AbstractString) -> Vector{SyntaxBlock}

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
function get_testblocks(interfaces::Vector{<:TestBlockInterface}, file::AbstractString)
    root = parseall(SyntaxNode, read(file, String); filename=file)
    return mapreduce(vcat, interfaces) do interface
        testblocks = Vector{SyntaxBlock}()
        get_testblocks!(interface, testblocks, root)
        testblocks
    end
end
function get_testblocks!(
    interface::TestBlockInterface,
    testblocks::Vector{SyntaxBlock},
    node::SyntaxNode,
    preamble::Vector{SyntaxNode}=SyntaxNode[],
)
    nodes = JuliaSyntax.children(node)
    isnothing(nodes) && return nothing
    for node in nodes
        if istestblock(interface, node)
            push!(testblocks, SyntaxBlock(copy(preamble), node, interface))
            get_testblocks!(interface, testblocks, node, copy(preamble))
        else
            get_testblocks!(interface, testblocks, node, copy(preamble))
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

# Arguments
- `interfaces::Vector{<:TestBlockInterface}`: Test block interfaces for parsing
- `root::AbstractString`: Root directory path for resolving relative file paths
- `matched_files::AbstractVector{<:AbstractString}`: List of files to parse

# Returns
- `Tuple{Dict{TestBlockInfo,SyntaxBlock}, Dict{String,TestBlockInfo}}`: 
  - First element: Maps test block info to syntax blocks
  - Second element: Maps formatted display strings to test block info

# Notes
The display strings are formatted with padding for alignment in fzf, showing:
`"<label> | <filename>:<line_start>-<line_end>"`
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
                (; testblock, interface) = syntax_block
                label = blocklabel(interface, testblock)
                line_start, _ = JuliaSyntax.source_location(
                    testblock.source, testblock.position
                )
                block_length = countlines(IOBuffer(JuliaSyntax.sourcetext(testblock)))
                line_end = line_start + block_length - 1
                TestBlockInfo(label, file, line_start, line_end) => syntax_block
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
    pick_testblock(tabled_keys, testset_query, root) -> Vector{String}

Present an interactive fzf interface for selecting test blocks to execute.

Launches fzf with a preview window (using bat) that allows users to select one or more
test blocks from the filtered list. The preview shows the actual test code with syntax
highlighting.

# Arguments
- `tabled_keys::Dict{String,TestBlockInfo}`: Mapping from display strings to test block info
- `testset_query::AbstractString`: Initial query to filter test block names
- `root::AbstractString`: Root directory for file path resolution

# Returns
- `Vector{String}`: List of selected display strings corresponding to chosen test blocks

# Features
- Multi-selection enabled (`-m` flag)
- Preview window shows test code with syntax highlighting
- Initial query pre-filters results
- Search limited to visible test labels (not file paths)
"""
function pick_testblock(
    tabled_keys::Dict{String,TestBlockInfo},
    testset_query::AbstractString,
    root::AbstractString,
)
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

# Arguments
- `choices::Vector{<:AbstractString}`: Selected display strings from fzf
- `info_to_syntax::Dict{TestBlockInfo,SyntaxBlock}`: Mapping from test info to syntax blocks
- `display_to_info::Dict{String,TestBlockInfo}`: Mapping from display strings to test info
- `pkg::PackageSpec`: Package specification for test context

# Returns
- `Vector{EvalTest}`: Collection of executable test objects ready for evaluation
"""
function testblock_list(
    choices::Vector{<:AbstractString},
    info_to_syntax::Dict{TestBlockInfo,SyntaxBlock},
    display_to_info::Dict{String,TestBlockInfo},
    pkg::PackageSpec,
)
    map(choices) do choice
        blockinfo = display_to_info[choice]
        syntax_block = info_to_syntax[blockinfo]
        (; label, file_name, line_start) = blockinfo
        test_info = TestInfo(file_name, label, line_start)
        (; preamble, testblock, interface) = syntax_block
        block_expr = expr_transform(
            interface, Expr(testblock), blockinfo, get_test_dir_from_pkg(pkg)
        )
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
    fzf_testblock(interfaces, fuzzy_file, fuzzy_testset) -> Nothing

Interactive test block selection and execution workflow using fzf.

Provides a two-stage fuzzy finding process:
1. Filter test files based on `fuzzy_file` query
2. Select specific test blocks from filtered files based on `fuzzy_testset` query

Selected test blocks are executed immediately with results saved to the package's
results file. The latest evaluation is stored in `LATEST_EVAL[]` for reference.

# Arguments
- `interfaces::Vector{<:TestBlockInterface}`: Test block interfaces for parsing
- `fuzzy_file::AbstractString`: Query pattern for filtering test files
- `fuzzy_testset::AbstractString`: Query pattern for filtering test block names

# Side Effects
- Executes selected test blocks
- Updates `LATEST_EVAL[]` with executed tests
- Cleans and writes to results file
- May modify package test state

# Examples
```julia
# Find and run tests matching "math" files and "addition" test names
fzf_testblock([StdTestset()], "math", "addition")
```
"""
function fzf_testblock(
    interfaces::Vector{<:TestBlockInterface},
    fuzzy_file::AbstractString,
    fuzzy_testset::AbstractString,
)
    pkg = current_pkg()
    root, test_files = get_test_files(pkg)
    # We fetch all valid test files.
    matched_files = get_matching_files(fuzzy_file, test_files)
    # We create  the collection of testsets based on the list of files.
    info_to_syntax, display_to_info = build_info_to_syntax(interfaces, root, matched_files)

    choices = pick_testblock(display_to_info, fuzzy_testset, root)
    if !isempty(choices)
        tests = testblock_list(choices, info_to_syntax, display_to_info, pkg)
        clean_results_file(pkg)
        LATEST_EVAL[] = tests
        for test in tests
            eval_in_module(test, pkg)
        end
    end
end
