```@meta
CurrentModule = TestPicker
```

# Writing a `TestBlockInterface`

By default `TestPicker` only recognizes standard `@testset` blocks (via [`StdTestset`](@ref)).
If your test files use another macro to define individual tests — for example
[`@testitem`](https://github.com/julia-vscode/TestItems.jl) — you can teach `TestPicker`
to recognize and run it by implementing your own [`TestBlockInterface`](@ref).

## The interface

A `TestBlockInterface` is an `abstract type` you subclass with a (usually singleton) struct.
Two methods are **required**, and two more are **optional**.

### Required methods

- [`istestblock`](@ref)`(interface, node::SyntaxNode)::Bool` — given a top-level syntax
  node from a parsed test file, decide whether it represents one of your test blocks.
- [`blocklabel`](@ref)`(interface, node::SyntaxNode)::String` — produce a human-readable,
  preferably unique label for the block, used for display and fuzzy matching in `fzf`.

Both are called on every top-level (and nested) node found in a test file, so they should
be cheap and side-effect free.

### Optional methods

- [`preamble`](@ref)`(interface)` — an `Expr` (or `nothing`) that should be evaluated once
  before any block of this type is run, e.g. to `using` a required package. Defaults to
  `nothing`.
- [`expr_transform`](@ref)`(interface, ex::Expr, info::TestBlockInfo, root::AbstractString)::Expr` —
  rewrite the block's expression before it gets evaluated. `info` carries the block's label,
  file name and line range; `root` is the package's test directory. Defaults to returning
  `ex` unchanged.

### Registering an interface

Once implemented, tell `TestPicker` about it with [`add_interface!`](@ref) (adds to the
existing interfaces) or [`replace_interface!`](@ref) (replaces all of them):

```julia
add_interface!(MyInterface())
```

## Example: recognizing `@testitem` blocks

`TestPicker` ships with [`TestItemInterface`](@ref) as a built-in example — enable it with
`add_testitem_interface!()`. Its implementation is a good template to follow:

```julia
struct TestItemInterface <: TestBlockInterface end

function istestblock(::TestItemInterface, node::SyntaxNode)
    kind(node) == K"macrocall" || return false
    nodes = JuliaSyntax.children(node)
    isnothing(nodes) && return false
    length(nodes) > 1 || return false
    kind(first(nodes)) == K"MacroName" || return false
    sourcetext(first(nodes)) == "testitem" || return false
    # The second node needs to be a descriptive `String`.
    return kind(nodes[2]) == K"string"
end

function blocklabel(::TestItemInterface, node::SyntaxNode)
    return sourcetext(only(JuliaSyntax.children(JuliaSyntax.children(node)[2])))
end

function preamble(::TestItemInterface)
    return :(using TestItemRunner)
end

function expr_transform(
    ::TestItemInterface, ::Expr, (; label, file_name)::TestBlockInfo, root::AbstractString
)
    return :(esc(
        TestItemRunner.run_tests(
            $(dirname(root));
            filter=ti ->
                (ti.name == $(label) && ti.filename == $(joinpath(root, file_name))),
        ),
    ))
end
```

A few things worth noting:

- `istestblock` walks the `SyntaxNode` children to check it is a `@testitem "..." begin ... end`
  macrocall, mirroring how `StdTestset` checks for `@testset`.
- `blocklabel` strips the surrounding quotes from the descriptive string so that it can be
  compared directly against `TestItemRunner`'s `ti.name`.
- Rather than running the parsed block's `Expr` directly, `expr_transform` discards it and
  instead builds a call to `TestItemRunner.run_tests`, filtering on the item's name and
  originating file. This is a good pattern whenever the underlying macro needs its own
  runner instead of being evaluated as plain Julia code.
- `preamble` ensures `TestItemRunner` is loaded before that generated call runs.

With `add_testitem_interface!()` registered, searching a test block query will surface both
`@testset` and `@testitem` blocks side by side.
