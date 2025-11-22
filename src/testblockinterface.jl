"""
    TestBlockInterface

Abstract interface for defining and recognizing different types of test blocks in Julia code.

The `TestBlockInterface` allows you to define different types of test blocks that you would like `TestPicker`
to find and evaluate. The interface is relatively simple and flexible.
"""
abstract type TestBlockInterface end

"""
    istestblock(interface::T, node::SyntaxNode)::Bool where {T<:TestBlockInterface}

Determine whether a syntax node represents a test block according to the given interface.

This is a required method that must be implemented by all concrete subtypes of
`TestBlockInterface`. It examines a syntax node and decides whether it represents
a test block that should be recognized by TestPicker.
"""
function istestblock(::T, node::SyntaxNode) where {T<:TestBlockInterface}
    return error("`istestblock` must be implemented for type $(T).")
end

"""
    blocklabel(interface::T, node::SyntaxNode)::String where {T<:TestBlockInterface}

Generate a descriptive label for a test block to be used in filtering and display.

This is a required method that must be implemented by all concrete subtypes of
`TestBlockInterface`. It should produce a (preferably) unique label that helps
users identify and select specific test blocks.
"""
function blocklabel(::T, node::SyntaxNode) where {T<:TestBlockInterface}
    return error("`blocklabel` must be implemented for type $(T).")
end

"""
    preamble(interface::TestBlockInterface)::Union{Nothing, Expr}

Return additional preamble code specific to the test block interface.

This optional method allows test block interfaces to specify setup code that should
be executed before any test blocks of this type. Common uses include importing
required packages or setting up test environment variables.
"""
function preamble(::TestBlockInterface)
    return nothing
end

"""
    prepend_preamble_statements(interface::TestBlockInterface, preambles::Vector{Expr}) -> Vector{Expr}

Combine interface-specific preamble with existing preamble statements.

Takes the preamble from the interface (if any) and prepends it to the existing
collection of preamble statements, ensuring interface requirements are satisfied
before test execution.
"""
function prepend_preamble_statements(interface::TestBlockInterface, preambles::Vector{Expr})
    interface_preamble = preamble(interface)
    if !isnothing(interface_preamble)
        vcat(interface_preamble, preambles)
    else
        preambles
    end
end

"""
    expr_transform(interface::TestBlockInterface, ex::Expr)::Expr

Transform a test block expression before evaluation.

This optional method allows test block interfaces to modify the test block
expression before it is executed. This can be useful for adding wrapper code,
modifying test behavior, or adapting different test formats.
"""
function expr_transform(::TestBlockInterface, ex::Expr)
    return ex
end

"""
    StdTestset <: TestBlockInterface

Standard implementation of [`TestBlockInterface`](@ref) for `@testset` blocks from Julia's `Test.jl` standard library.

This is the built-in interface for recognizing and processing standard Julia test sets.
It handles `@testset` blocks commonly used in Julia testing and provides the necessary
preamble to load the Test.jl package.
"""
struct StdTestset <: TestBlockInterface end

function istestblock(::StdTestset, node::SyntaxNode)
    kind(node) == K"macrocall" || return false
    nodes = JuliaSyntax.children(node)
    isnothing(nodes) && return false
    length(nodes) > 1 || return false
    kind(first(nodes)) == K"MacroName" || return false
    sourcetext(first(nodes)) == "testset" || return false
    # The second node needs to be descriptive `String`.
    return kind(nodes[2]) == K"string"
end

function blocklabel(::StdTestset, node::SyntaxNode)
    return sourcetext(JuliaSyntax.children(node)[2])
end

function preamble(::StdTestset)
    return :(using Test)
end
