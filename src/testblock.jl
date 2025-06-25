"""
The `TestBlockInterface` allows you to define different type of test blocks that you would like `TestPicker`
to find and evaluate.
The interface is relatively simple. Assuming that you are defining your own type `struct MyTestBlock <: TestBlockInterface end`:

## Required methods
- `istestblock(::MyTestBlock, node::SyntaxNode)::Bool`: indicates whether a given `SyntaxNode` represents a desirable test block.
- `blocklabel(::MyTestBlock, node::SyntaxNode)::String`: for a given node, produce a (preferably) unique label that will be used for filtering and display.

## Optional methods
- `preamble(::MyTestBlock)::Union{Nothing, Expr}`: eventually additional preamble that the given testblock might require. Default: `nothing`.
- `expr_transform(::MyTestBlock, ex::Expr)::Expr`: eventually transform the test block expression into a different one. Default: `identity`.
"""
abstract type TestBlockInterface end

"""
    istestblock(::T, node::SyntaxNode)::Bool where {T<:TestBlockInterface}

Predicate on whether the node represent a test block according to its interface.
"""
function istestblock(::T, node::SyntaxNode) where {T<:TestBlockInterface}
    return error("`istestblock` must be implemented for type $(T).")
end

"""
    blocklabel(::T, node::SyntaxNode)::String where {T<:TestBlockInterface}

Return a (preferably) unique label given the test block as a `SyntaxNode`.
"""
function blocklabel(::T, node::SyntaxNode) where {T<:TestBlockInterface}
    return error("`blocklabel` must be implemented for type $(T).")
end

"""
    preamble(::TestBlockInterface)::Union{Nothing, Expr}

Return an additional preamble specific to the inferface.
"""
function preamble(::TestBlockInterface)
    return nothing
end

function prepend_preamble_statements(interface::TestBlockInterface, preambles::Vector{Expr})
    interface_preamble = preamble(interface)
    if !isnothing(interface_preamble)
        vcat(interface_preamble, preambles)
    else
        preambles
    end
end

"""
    expr_transform(::TestBlockInterface, ex::Expr)::Expr

Perform an additional transformation on the test block as an `Expr`.
"""
function expr_transform(::TestBlockInterface, ex::Expr)
    return ex
end

"""
Implementation of the [`TestBlockInterface`](@ref) for the `@testset` blocks from the `Test.jl` Julia standard library.
"""
struct StdTestset <: TestBlockInterface end

function istestblock(::StdTestset, node::SyntaxNode)
    nodes = JuliaSyntax.children(node)
    return !isnothing(nodes) && !isempty(nodes) && Expr(first(nodes)) == Symbol("@testset")
end

function blocklabel(::StdTestset, node::SyntaxNode)
    return JuliaSyntax.sourcetext(JuliaSyntax.children(node)[2])
end

function preamble(::StdTestset)
    return :(using Test)
end

"Check if a statement qualifies as a preamble."
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
A `SyntaxBlock` contains the test block as well as the required preamble as a collection of `SyntaxNode`.
It can easily be converted into an evaluatable expression.
"""
struct SyntaxBlock
    preamble::Vector{SyntaxNode}
    testblock::SyntaxNode
    interface::TestBlockInterface
end

"""
Fetch all the test blocks nodes from the given `file` and for each testset (included nested ones) collect all preamble statements (see [`ispreamble`](@ref)).
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
Run a non-interactive command that return all the files getting the match on the given query.
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
Struct representing metadata about a testblock such as its label,
the filename is taken from, and the starting and ending line numbers.
"""
struct TestBlockInfo
    label::String
    file_name::String
    line_start::Int
    line_end::Int
end

label(info::TestBlockInfo) = info.label
file_name(info::TestBlockInfo) = info.file_name

"""
Given a list of matched files, extract all contained testblock, and build a map
that maps some displayable name for `fzf` to the relevant data structure.
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
Call `fzf` again to chose which testset to evaluate. The preview is done using `bat`.
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
        block_expr = expr_transform(interface, Expr(testblock))
        tried_testset = quote
            try
                $(block_expr)
            catch e
                !(e isa TestSetException) && rethrow()
                TestPicker.save_test_results(e, $(test_info), $(pkg))
            end
        end
        preamble_statements = prepend_interface_preamble(interface, Expr.(preamble))
        ex = Expr(:block, preamble_statements..., tried_testset)
        EvalTest(ex, test_info)
    end
end

"Given a `fuzzy_file` query and a testset `query` return all possible testset that match both the file and the testset names, provide a choice and execute it."
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
