"Check whether the given `SyntaxNode` is a `@testset` macro block"
function is_testset(node::SyntaxNode)
    return !isempty(JuliaSyntax.children(node)) &&
           Expr(first(JuliaSyntax.children(node))) == Symbol("@testset")
end

function get_all_nodes(file::AbstractString)
    root = parseall(SyntaxNode, read(file, String); filename=file)
    top_nodes = JuliaSyntax.children(root)
    meta_nodes = filter(!is_testset, top_nodes)
    testsets = filter(is_testset, top_nodes)
    return meta_nodes, testsets
end

function select_and_run_testset(fuzzy_file::AbstractString, query::AbstractString)
    root, test_files = get_test_files()
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
    full_map = mapreduce(merge, matched_files) do file
        max_file = max(max_file, length(file))
        meta, testsets = get_all_nodes(joinpath(root, file))
        stringified_tests = map(testsets) do node
            name = JuliaSyntax.sourcetext(JuliaSyntax.children(node)[2])
            line, _ = JuliaSyntax.source_location(node.source, node.position)
            max_name = max(max_name, length(name))
            name, file, line
        end
        Dict(stringified_tests .=> (testsets .=> Ref(meta)))
    end
    tabled_keys = Dict(
        map(collect(keys(full_map))) do (name, file, line)
            "$(rpad(name, max_name + 2)) | $(lpad(file, max_file + 2)):$(line)"
        end .=> keys(full_map),
    )

    choice = fzf() do exe
        chomp(
            read(
                pipeline(
                    Cmd(`$(exe) --query $(query)`; ignorestatus=true);
                    stdin=IOBuffer(join(keys(tabled_keys), '\n')),
                ),
                String,
            ),
        )
    end
    if !isempty(choice)
        testset, meta = full_map[tabled_keys[choice]]
        ex = Expr(:block)
        init = Expr.(meta)
        append!(ex.args, init)
        push!(ex.args, Expr(testset))
        pkg = current_pkg()
        @show ex
        eval_in_module(ex, pkg)
    end
end
