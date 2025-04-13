"Check whether the given `SyntaxNode` is a `@testset` macro block."
function is_testset(node::SyntaxNode)
    return !isempty(JuliaSyntax.children(node)) &&
           Expr(first(JuliaSyntax.children(node))) == Symbol("@testset")
end

"Fetch all the top nodes from `file` and split them between a `preamble` and `testsets`."
function get_preamble_testsets(file::AbstractString)
    root = parseall(SyntaxNode, read(file, String); filename=file)
    top_nodes = JuliaSyntax.children(root)
    preamble_nodes = filter(!is_testset, top_nodes)
    testsets = filter(is_testset, top_nodes)
    return preamble_nodes, testsets
end

"Build the command line function to be run by `fzf` to preview the relevant code lines."
function build_preview_arg(rg::String, bat::String)
    return "\$(echo {} | $rg \"\\|\\s+(.*):(\\d*)-(\\d*)\" -or \'$bat --color=always --line-range=\$2:\$3 \$1\')"
end

"Fetch the last leaf from the given node to try to get the ending line of the the testset block."
function last_leaf(node)
    if isempty(JuliaSyntax.children(node))
        node
    else
        last_leaf(last(JuliaSyntax.children(node)))
    end
end

"""
Run a non-interactive command that return all the files getting the match on the given query.
"""
function get_matching_files(
    file_query::AbstractString, test_files::AbstractVector{<:AbstractString}
)
    fzf() do exe
        readlines(
            pipeline(
                Cmd(`$(exe) --filter $(file_query)`; ignorestatus=true);
                stdin=IOBuffer(join(test_files, '\n')),
            ),
        )
    end
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
        preamble, testsets = get_preamble_testsets(joinpath(root, file))
        testsets_info = map(testsets) do node
            name = JuliaSyntax.sourcetext(JuliaSyntax.children(node)[2])
            line_start, _ = JuliaSyntax.source_location(node.source, node.position)
            block_length = countlines(IOBuffer(JuliaSyntax.sourcetext(node)))
            line_end = line_start + block_length - 1
            TestsetInfo(name, file, line_start, line_end)
        end
        Dict(testsets_info .=> (testsets .=> Ref(preamble)))
    end
    max_testset_length = maximum(length ∘ testset_name, keys(full_map))
    max_filename_length = maximum(length ∘ file_name, keys(full_map))
    # We create a new mapping with human readable lines for fzf.
    tabled_keys = Dict(
        map(
            collect(keys(full_map))
        ) do (; testset_name, file_name, line_start, line_end)
            "$(rpad(testset_name, max_testset_length + 2)) | $(lpad(file_name,  max_filename_length + 2)):$(line_start)-$(line_end)"
        end .=> keys(full_map),
    )
    return full_map, tabled_keys
end

"""
Call `fzf` again to chose which testset to evaluate. The preview is done using `rg` and `bat`.
"""
function pick_testset(
    tabled_keys::Dict, testset_query::AbstractString, root::AbstractString
)
    # Leave the user the choice of a testset.
    rg() do rg_exe
        fzf() do fzf_exe
            bat() do bat_exe
                cmd = Cmd(
                    String[
                        fzf_exe,
                        "--preview",
                        build_preview_arg(rg_exe, bat_exe),
                        "--query",
                        testset_query,
                    ],
                )
                chomp(
                    read(
                        pipeline(
                            addenv(
                                Cmd(cmd; ignorestatus=true, dir=root),
                                "SHELL" => Sys.which("bash"),
                            );
                            stdin=IOBuffer(join(keys(tabled_keys), '\n')),
                        ),
                        String,
                    ),
                )
            end
        end
    end
end

"Given a `fuzzy_file` query and a testset `query` return all possible testset that match both the file and the testset names, provide a choice and execute it."
function select_and_run_testset(fuzzy_file::AbstractString, fuzzy_testset::AbstractString)
    root, test_files = get_test_files()
    # We fetch all valid test files.
    matched_files = get_matching_files(fuzzy_file, test_files)
    # We create  the collection of testsets based on the list of files.
    full_map, tabled_keys = build_file_testset_map(root, matched_files)

    choice = pick_testset(tabled_keys, fuzzy_testset, root)
    if !isempty(choice)
        testset_info = tabled_keys[choice]
        testset, preamble = full_map[testset_info]
        ex = Expr(:block, Expr.(preamble)..., Expr(testset))
        pkg = current_pkg()
        (; testset_name, file_name, line_start) = testset_info
        test = TestInfo(ex, file_name, testset_name, line_start)
        LATEST_EVAL[] = [test]
        eval_in_module(test, pkg)
    end
end
