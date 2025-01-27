function is_testset(node::SyntaxNode)
    return Expr(first(JuliaSyntax.children(node))) == Symbol("@testset")
end

function get_all_nodes(file::AbstractString)
    root = parseall(SyntaxNode, read(file, String); filename=file)
    top_nodes = JuliaSyntax.children(root)
    meta_nodes = filter(!is_testset, top_nodes)
    testsets = filter(is_testset, top_nodes)
    return meta_nodes, testsets
end

function select_testset(fuzzy_file::AbstractString, query::AbstractString)
    root, test_files = get_test_files()
    matched_files = fzf() do exe
        readlines(
            pipeline(
                Cmd(`$(exe) --filter $(fuzzy_file)`; ignorestatus=true);
                stdin=IOBuffer(join(test_files, '\n')),
            ),
        )
    end
    full_map = mapreduce(merge, matched_files) do file
        meta, testsets = get_all_nodes(joinpath(root, file))
        stringified_tests = map(testsets) do node
            name = JuliaSyntax.sourcetext(JuliaSyntax.children(node)[2])
            line, _ = JuliaSyntax.source_location(node.source, node.position)
            "$(name): $(file):$(line)"
        end
        Dict(stringified_tests .=> (testsets .=> Ref(meta)))
    end

    choice = fzf() do exe
        chomp(
            read(
                pipeline(
                    Cmd(`$(exe) --query $(query)`; ignorestatus=true);
                    stdin=IOBuffer(join(keys(full_map), '\n')),
                ),
                String,
            ),
        )
    end

    if !isempty(choice)
        testset, meta = full_map[choice]
        ex = Expr(:toplevel)
        init = Expr.(meta)
        append!(ex.args, init)
        push!(ex.args, Expr(testset))
        pkg = current_pkg()
        TestEnv.activate(pkg) do
            Base.eval(Main, ex)
        end
    end
end
