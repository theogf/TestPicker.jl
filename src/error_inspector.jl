"""
    inspect_error(err=last_exception(); pkg=current_pkg_or_nothing(), repl=Base.active_repl)

Explore the stacktrace of any exception with the same interactive viewer used for test
results, see [`visualize_stacktrace`](@ref).

`err` can be
- an exception stack, e.g. the `err` variable set by the REPL after an error (this is
  what is used when `inspect_error` is called without argument),
- a `(; exception, backtrace)` entry of such a stack,
- an exception, optionally followed by its backtrace,
- the raw text of an error, as printed in the REPL.

# Examples

```julia-repl
julia> sqrt(-1)
ERROR: DomainError with -1.0:
[...]

julia> inspect_error()  # equivalent to `inspect_error(err)`
```

The same viewer is reachable from test mode with `test> @e`.
"""
function inspect_error(
    text::AbstractString;
    pkg::Union{Nothing,PackageSpec}=current_pkg_or_nothing(),
    repl::Union{Nothing,AbstractREPL}=nothing,
    kwargs...,
)
    terminal = isnothing(repl) ? nothing : repl.t
    found = visualize_stacktrace(text; pkg, terminal, kwargs...)
    found || @warn "No stacktrace could be found in the given error:\n$(text)"
    return nothing
end

function inspect_error(stack::Base.ExceptionStack; kwargs...)
    if isempty(stack)
        @warn "The given exception stack is empty."
        return nothing
    end
    return inspect_error(error_text(stack); kwargs...)
end

function inspect_error(entry::NamedTuple{(:exception, :backtrace)}; kwargs...)
    return inspect_error(entry.exception, entry.backtrace; kwargs...)
end

function inspect_error(exception::Exception, backtrace=[]; kwargs...)
    return inspect_error(error_text(exception, backtrace); kwargs...)
end

function inspect_error(; kwargs...)
    err = last_exception()
    if isnothing(err)
        @warn "No exception was thrown yet in this session."
        return nothing
    end
    return inspect_error(err; kwargs...)
end

"""
    last_exception() -> Union{Nothing,Base.ExceptionStack}

Exception stack of the last error thrown at the REPL, i.e. the content of the `err`
variable, or `nothing` if no error was thrown yet.
"""
function last_exception()
    isdefined(Main, :err) || return nothing
    err = getglobal(Main, :err)
    (isnothing(err) || (err isa Base.ExceptionStack && isempty(err))) && return nothing
    return err
end

"Textual representation of an error (and its backtrace), as printed in the REPL."
error_text(stack::Base.ExceptionStack) = sprint_error(stack)
error_text(exception, backtrace) = sprint_error(exception, backtrace)

function sprint_error(args...)
    sprint(Base.display_error, args...; context=(:color => true, :limit => true))
end
