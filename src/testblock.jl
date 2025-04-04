"Check whether the given `SyntaxNode` is a `@testset` macro block"
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

function build_preview_arg(rg::String, bat::String)
    return "\$(echo {} | $rg \"\\|\\s+(.*):(\\d*)-(\\d*)\" -or \'$bat --color=always --line-range=\$2:\$3 \$1\')"
end

function last_leaf(node)
    if isempty(JuliaSyntax.children(node))
        node
    else
        last_leaf(last(JuliaSyntax.children(node)))
    end
end

"Given a `fuzzy_file` query and a testset `query` return all possible testset that match both the file and the testset names, provide a choice and execute it."
function select_and_run_testset(fuzzy_file::AbstractString, query::AbstractString)
    root, test_files = get_test_files()
    # We fetch all valid test files.
    matched_files = fzf() do exe
        readlines(
            pipeline(
                Cmd(`$(exe) --filter $(fuzzy_file)`; ignorestatus=true);
                stdin=IOBuffer(join(test_files, '\n')),
            ),
        )
    end
    max_name = 0
    max_file = 0
    # We create  the collection of testsets based on the list of files.
    full_map = mapreduce(merge, matched_files) do file
        # Keep track of file name length for padding.
        max_file = max(max_file, length(file))
        preamble, testsets = get_preamble_testsets(joinpath(root, file))
        name_file_line = map(testsets) do node
            name = JuliaSyntax.sourcetext(JuliaSyntax.children(node)[2])
            line_start, _ = JuliaSyntax.source_location(node.source, node.position)
            line_end, _ = JuliaSyntax.source_location(node.source, last_leaf(node).position)
            max_name = max(max_name, length(name))
            name, file, line_start, line_end + 1
        end
        Dict(name_file_line .=> (testsets .=> Ref(preamble)))
    end
    # We create a new mapping with human readable lines.
    tabled_keys = Dict(
        map(collect(keys(full_map))) do (name, file, line_start, line_end)
            "$(rpad(name, max_name + 2)) | $(lpad(file, max_file + 2)):$(line_start)-$(line_end)"
        end .=> keys(full_map),
    )

    # preview_cmd = "$(get_display_block_cmd()) $(root)/{-1}"
    # Leave the user the choice of a testset.
    choice = rg() do rg_exe
        fzf() do fzf_exe
            bat() do bat_exe
                cmd = Cmd(String[
                    fzf_exe,
                    "--preview",
                    build_preview_arg(rg_exe, bat_exe),
                    "--query",
                    query
                ])
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
    if !isempty(choice)
        name_file_line = tabled_keys[choice]
        testset, preamble = full_map[name_file_line]
        ex = Expr(:block, Expr.(preamble)..., Expr(testset))
        pkg = current_pkg_name()
        name, file, line = name_file_line
        @info "Executing testset $(name) from $(file):$(line)"
        eval_in_module(ex, pkg)
    end
end
