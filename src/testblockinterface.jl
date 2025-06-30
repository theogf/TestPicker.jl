"""
    TestBlockInterface

Abstract interface for defining and recognizing different types of test blocks in Julia code.

The `TestBlockInterface` allows you to define different types of test blocks that you would like `TestPicker`
to find and evaluate. The interface is relatively simple and flexible.

# Implementation Requirements

To create a custom test block interface, define a subtype and implement the required methods:
```julia
struct MyTestBlock <: TestBlockInterface end
```

## Required Methods
- [`istestblock(::MyTestBlock, node::SyntaxNode)::Bool`](@ref istestblock): Determines whether a given `SyntaxNode` represents a test block
- [`blocklabel(::MyTestBlock, node::SyntaxNode)::String`](@ref blocklabel): Produces a (preferably) unique label for filtering and display

## Optional Methods  
- [`preamble(::MyTestBlock)::Union{Nothing, Expr}`](@ref preamble): Returns additional preamble that the test block might require (default: `nothing`)
- [`expr_transform(::MyTestBlock, ex::Expr)::Expr`](@ref expr_transform): Transforms the test block expression before evaluation (default: identity)

# Examples
```julia
# Define a custom interface for @test_nowarn blocks
struct NoWarnTestInterface <: TestBlockInterface end

function istestblock(::NoWarnTestInterface, node::SyntaxNode)
    nodes = JuliaSyntax.children(node)
    return !isnothing(nodes) && !isempty(nodes) && 
           Expr(first(nodes)) == Symbol("@test_nowarn")
end

function blocklabel(::NoWarnTestInterface, node::SyntaxNode)
    return "nowarn: " * JuliaSyntax.sourcetext(JuliaSyntax.children(node)[2])
end
```
"""
abstract type TestBlockInterface end

"""
    istestblock(interface::T, node::SyntaxNode)::Bool where {T<:TestBlockInterface}

Determine whether a syntax node represents a test block according to the given interface.

This is a required method that must be implemented by all concrete subtypes of
`TestBlockInterface`. It examines a syntax node and decides whether it represents
a test block that should be recognized by TestPicker.

# Arguments
- `interface::T`: The test block interface implementation
- `node::SyntaxNode`: The syntax node to examine

# Returns  
- `Bool`: `true` if the node represents a test block, `false` otherwise

# Examples
```julia
# For @testset blocks:
function istestblock(::StdTestset, node::SyntaxNode)
    nodes = JuliaSyntax.children(node)
    return !isnothing(nodes) && !isempty(nodes) && 
           Expr(first(nodes)) == Symbol("@testset")
end
```
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

# Arguments
- `interface::T`: The test block interface implementation  
- `node::SyntaxNode`: The syntax node representing the test block

# Returns
- `String`: A descriptive label for the test block

# Implementation Notes
- Labels should be human-readable and distinctive
- Consider including test names, descriptions, or other identifying information

# Examples
```julia
# For @testset blocks, extract the test set name:
function blocklabel(::StdTestset, node::SyntaxNode)
    return JuliaSyntax.sourcetext(JuliaSyntax.children(node)[2])
end
```
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

# Arguments
- `interface::TestBlockInterface`: The test block interface implementation

# Returns
- `Union{Nothing, Expr}`: Preamble expression to execute, or `nothing` if no preamble needed

# Default Behavior
The default implementation returns `nothing`, indicating no additional preamble is required.

# Examples
```julia
# StdTestset requires Test.jl to be loaded:
function preamble(::StdTestset)
    return :(using Test)
end

# Custom interface might need multiple setup steps:
function preamble(::MyCustomInterface)
    return quote
        using Test, Random
        Random.seed!(1234)
    end
end
```
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

# Arguments
- `interface::TestBlockInterface`: The test block interface implementation
- `preambles::Vector{Expr}`: Existing preamble statements from the test file

# Returns
- `Vector{Expr}`: Combined preamble statements with interface preamble first

# Examples
```julia
interface = StdTestset()
existing = [:(x = 1), :(y = 2)]
result = prepend_preamble_statements(interface, existing)
# Returns: [:(using Test), :(x = 1), :(y = 2)]
```
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

# Arguments
- `interface::TestBlockInterface`: The test block interface implementation
- `ex::Expr`: The test block expression to transform

# Returns
- `Expr`: The transformed expression ready for evaluation

# Default Behavior
The default implementation returns the expression unchanged (identity transformation).

# Examples
```julia
# Add timing information to test blocks:
function expr_transform(::TimedTestInterface, ex::Expr)
    return quote
        start_time = time()
        result = \$ex
        elapsed = time() - start_time
        println("Test completed in \$(elapsed)s")
        result
    end
end

# Wrap tests in additional error handling:
function expr_transform(::SafeTestInterface, ex::Expr)
    return quote
        try
            \$ex
        catch e
            @warn "Test failed with error: \$e"
            rethrow()
        end
    end
end
```
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

# Behavior
- Recognizes syntax nodes that start with `@testset`
- Extracts test set names as labels for display
- Automatically includes `using Test` as preamble
- No expression transformation (uses default identity)

# Examples
```julia
# This testset would be recognized:
@testset "Basic arithmetic tests" begin
    @test 1 + 1 == 2
    @test 2 * 3 == 6
end

# The label would be: "Basic arithmetic tests"
```
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
