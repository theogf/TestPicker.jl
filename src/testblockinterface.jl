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
