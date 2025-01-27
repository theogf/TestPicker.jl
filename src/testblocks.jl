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

function select_testset(file::AbstractString)
    meta, testsets = get_all_nodes(file)
    stringified_tests = map(testsets) do node
        name = JuliaSyntax.sourcetext(JuliaSyntax.children(node)[2])
        line, _ = JuliaSyntax.source_location(node.source, node.position)
        "$(name): $(file):$(line)"
    end
    test_mapper = Dict(stringified_tests .=> testsets)
    ex = Expr(:toplevel)
    init = Expr.(meta)
    append!(ex.args, init)
    choice = fzf() do exe
        chomp(
            read(
                pipeline(
                    Cmd(`$(exe)`; ignorestatus=true);
                    stdin=IOBuffer(join(stringified_tests, '\n')),
                ),
                String,
            ),
        )
    end
    if !isempty(choice)
        push!(ex.args, Expr(test_mapper[choice]))
        Base.eval(Main, ex)
    end
end
