"Check whether the given `SyntaxNode` is a `@testset` macro block."
function is_testnode(node::SyntaxNode, testnodes::Vector{Symbol}=testnode_symbols())
    nodes = JuliaSyntax.children(node)
    return !isnothing(nodes) && !isempty(nodes) && Expr(first(nodes)) ∈ testnodes
end

"""
Fetch all potential test block that can be fetched from the testset parsing.
Other nodes than `@testset` can be added (coma separated) via `ENV["TESTPICKER_NODES"]`.
"""
function testnode_symbols()
    nodes = [Symbol("@testset")]
    if haskey(ENV, "TESTPICKER_NODES")
        str = ENV["TESTPICKER_NODES"]
        names = strip.(split(str, ','))
        all(startswith("@"), names) ||
            @warn "The following provided names under `ENV[\"TESTPICKER_NODES\"]` are not macros." non_symbols = filter(
                !startswith("@"), names
            )
        append!(nodes, Symbol.(filter(startswith("@"), names)))
    end
    return nodes
end

"Check if a statement qualifies as a preamble."
function is_preamble(node::SyntaxNode)
    ex = Expr(node)
    Meta.isexpr(ex, :call) && return true
    Meta.isexpr(ex, :using) && return true
    Meta.isexpr(ex, :import) && return true
    Meta.isexpr(ex, :(=)) && return true
    Meta.isexpr(ex, :macrocall) && return true
    Meta.isexpr(ex, :function) && return true
    return false
end

"Fetch all the nodes from the given `file` and for each testset (included nested ones) collect all preamble statements (see [`is_preamble`](@ref))."
function get_testsets_with_preambles(file::AbstractString)
    root = parseall(SyntaxNode, read(file, String); filename=file)
    testsets_with_preambles = Vector{Pair{SyntaxNode,Vector{SyntaxNode}}}()
    testnodes = testnode_symbols()
    get_testsets_with_preambles!(testsets_with_preambles, root, testnodes)
    return testsets_with_preambles
end
function get_testsets_with_preambles!(
    testsets_with_preambles,
    node::SyntaxNode,
    testnodes::Vector{Symbol},
    preamble::Vector{SyntaxNode}=SyntaxNode[],
)
    nodes = JuliaSyntax.children(node)
    isnothing(nodes) && return nothing
    for node in nodes
        if is_testnode(node, testnodes)
            push!(testsets_with_preambles, (node => copy(preamble)))
            get_testsets_with_preambles!(
                testsets_with_preambles, node, testnodes, copy(preamble)
            )
        else
            get_testsets_with_preambles!(
                testsets_with_preambles, node, testnodes, copy(preamble)
            )
            if is_preamble(node)
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
Struct representing metadata about a testset.
"""
struct TestsetInfo
    testset_name::String
    file_name::String
    line_start::Int
    line_end::Int
end

testset_name(info::TestsetInfo) = info.testset_name
file_name(info::TestsetInfo) = info.file_name

"""
Given a list of matched files, extract all contained testsets, and build a map
that maps some displayable name for `fzf` to the relevant data structure.
"""
function build_file_testset_map(
    root::AbstractString, matched_files::AbstractVector{<:AbstractString}
)
    full_map = mapreduce(merge, matched_files) do file
        # Keep track of file name length for padding.
        testsets_preambles = get_testsets_with_preambles(joinpath(root, file))
        Dict(
            map(testsets_preambles) do (testset, preambles)
                name = JuliaSyntax.sourcetext(JuliaSyntax.children(testset)[2])
                line_start, _ = JuliaSyntax.source_location(
                    testset.source, testset.position
                )
                block_length = countlines(IOBuffer(JuliaSyntax.sourcetext(testset)))
                line_end = line_start + block_length - 1
                TestsetInfo(name, file, line_start, line_end) => (testset => preambles)
            end,
        )
    end
    max_testset_length = maximum(length ∘ testset_name, keys(full_map))
    max_filename_length = maximum(length ∘ file_name, keys(full_map))
    # We create a new mapping with human readable lines for fzf.
    tabled_keys = Dict(
        map(
            collect(keys(full_map))
        ) do (; testset_name, file_name, line_start, line_end)
            visible_text = "$(rpad(testset_name, max_testset_length + 2)) | $(lpad(file_name,  max_filename_length + 2)):$(line_start)-$(line_end)"
            join([visible_text, file_name, line_start, line_end], separator())
        end .=> keys(full_map),
    )
    return full_map, tabled_keys
end

"""
Call `fzf` again to chose which testset to evaluate. The preview is done using `bat`.
"""
function pick_testset(
    tabled_keys::Dict, testset_query::AbstractString, root::AbstractString
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

function build_testset_list(choices, full_map, tabled_keys, pkg::PackageSpec)
    map(choices) do choice
        testset_info = tabled_keys[choice]
        testset, preamble = full_map[testset_info]
        (; testset_name, file_name, line_start) = testset_info
        test_info = TestInfo(file_name, testset_name, line_start)
        tried_testset = quote
            try
                $(Expr(testset))
            catch e
                !(e isa TestSetException) && rethrow()
                TestPicker.save_test_results(e, $(test_info), $(pkg))
            end
        end
        ex = Expr(:block, Expr.(preamble)..., tried_testset)
        EvalTest(ex, test_info)
    end
end

"Given a `fuzzy_file` query and a testset `query` return all possible testset that match both the file and the testset names, provide a choice and execute it."
function fzf_testset(fuzzy_file::AbstractString, fuzzy_testset::AbstractString)
    pkg = current_pkg()
    root, test_files = get_test_files(pkg)
    # We fetch all valid test files.
    matched_files = get_matching_files(fuzzy_file, test_files)
    # We create  the collection of testsets based on the list of files.
    full_map, tabled_keys = build_file_testset_map(root, matched_files)

    choices = pick_testset(tabled_keys, fuzzy_testset, root)
    if !isempty(choices)
        tests = build_testset_list(choices, full_map, tabled_keys, pkg)
        clean_results_file(pkg)
        LATEST_EVAL[] = tests
        for test in tests
            eval_in_module(test, pkg)
        end
    end
end
