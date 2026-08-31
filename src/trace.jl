"""
    TraceFrame

One frame of a stacktrace, in the intermediate representation shared by every source of
errors TestPicker can display.

`text` is what the picker shows for the frame (it may carry ANSI codes, and usually spans
the two lines Julia prints per frame), while the other fields are the structured data the
preview and the editor binding need. `file` is the path as resolved by
`Base.find_source_file`, i.e. an absolute path, or `nothing` when the frame has no source
we can open (`REPL[1]`, `none:0`, C frames...). `line` is `0` in that case.

Frames come either from a real backtrace ([`trace_error`](@ref) on an exception) or from
parsing printed stacktrace text ([`trace_error`](@ref) on a `String`), and are serialized
to JSON in the results file, see [`TestResultEntry`](@ref).
"""
struct TraceFrame
    text::String
    file::Union{Nothing,String}
    line::Int
    func::String
    mod::Union{Nothing,String}
    inlined::Bool
end

"""
    TraceError

An error message together with the [`TraceFrame`](@ref)s of its stacktrace.

`frames` is empty when no stacktrace could be obtained, which is the case for test
failures (as opposed to errors) and for exceptions thrown before any frame was recorded.
"""
struct TraceError
    header::String
    frames::Vector{TraceFrame}
end

"Whether the given line starts a new stack frame, e.g. ` [12] some_call(...)`."
is_frame_start(line::AbstractString) = !isnothing(match(r"^\s*\[\d+\]", line))

"""
Group the lines of a printed stacktrace into frames.

A frame starts at a line of the form ` [i] some_call(...)` and holds every line until the
next one (usually a single ` @ Module path:line` line, but exception chains (`caused by:`)
or task errors can add more).
"""
function group_frames(lines::AbstractVector{<:AbstractString})
    frames = Vector{eltype(lines)}[]
    for line in lines
        if is_frame_start(line) || isempty(frames)
            push!(frames, [line])
        else
            push!(last(frames), line)
        end
    end
    return frames
end

"""
    trace_error(text::AbstractString) -> TraceError

Parse printed stacktrace text (the output of `showerror`, or the string `Test.Error`
stores) into a [`TraceError`](@ref).

This is the lossy of the two parsers: file and line are recovered with a regular
expression, so frames whose location Julia does not print as `path.jl:line` (`REPL[1]`,
`none:0`) or whose path contains a space come out without a source. Prefer
[`trace_error`](@ref) on the exception itself whenever the backtrace is still available.
"""
function trace_error(text::AbstractString)
    lines = split(text, '\n')
    start_stack = findfirst(is_frame_start, lines)
    isnothing(start_stack) && return TraceError(text, TraceFrame[])
    header = join(lines[1:(start_stack - 2)], '\n')
    frames = map(group_frames(lines[start_stack:end])) do group
        frame_text = join(group, '\n')
        location = match(r"(\S+\.jl):(\d+)", frame_text)
        if isnothing(location)
            TraceFrame(frame_text, nothing, 0, printed_func(frame_text), nothing, false)
        else
            file, line = remove_ansi.(location.captures)
            TraceFrame(
                frame_text,
                Base.find_source_file(expanduser(file)),
                Base.parse(Int, line),
                printed_func(frame_text),
                nothing,
                contains(frame_text, "[inlined]"),
            )
        end
    end
    return TraceError(header, frames)
end

"""
The name of the function a printed frame belongs to, i.e. what sits between the frame
number and the argument list. Enough to recognize the `top-level scope` and
`macro expansion` frames the line repair works on.
"""
function printed_func(frame_text::AbstractString)
    header = remove_ansi(first(eachsplit(frame_text, '\n')))
    m = match(r"^\s*\[\d+\]\s*(.*)$", header)
    isnothing(m) && return ""
    name = only(m.captures)
    args = findfirst('(', name)
    isnothing(args) && return String(strip(name))
    trimmed = strip(name[1:prevind(name, args)])
    return String(isempty(trimmed) ? strip(name) : trimmed)
end

"""
    trace_error(stack::Base.ExceptionStack) -> TraceError
    trace_error(exception, backtrace) -> TraceError

Build a [`TraceError`](@ref) from a real, in-memory backtrace.

Every field comes straight from the `StackTraces.StackFrame`s, so no text has to be parsed
back: the source of each frame is exact, even when Julia would print it as a relative or
otherwise unparseable path.

For an exception stack, the frames are those of the exception on top of the stack (the one
Julia reports first) and the messages of the exceptions it was caused by are appended to
the header, mirroring `Base.show_exception_stack`.
"""
function trace_error(stack::Base.ExceptionStack)
    isempty(stack) && return TraceError("", TraceFrame[])
    # `show_exception_stack` reports the stack top first and the causes below it.
    messages = [error_message(exception) for (; exception) in Iterators.reverse(stack)]
    header = join(messages, "\ncaused by: ")
    return TraceError(header, trace_frames(last(stack).backtrace))
end

function trace_error(exception, backtrace)
    return TraceError(error_message(exception), trace_frames(backtrace))
end

"Message of a single exception, without its stacktrace."
function error_message(exception)
    return sprint(Base.showerror, exception; context=(:color => true, :limit => true))
end

"Resolve a raw backtrace into [`TraceFrame`](@ref)s."
function trace_frames(backtrace)
    isnothing(backtrace) && return TraceFrame[]
    frames = stacktrace(backtrace)
    return [trace_frame(i, frame) for (i, frame) in enumerate(frames)]
end

function trace_frame(i::Int, frame::StackTraces.StackFrame)
    file = string(frame.file)
    mod = Base.parentmodule(frame)
    location = string(file, ":", frame.line)
    TraceFrame(
        string(
            " [",
            i,
            "] ",
            frame_signature(frame),
            "\n   @ ",
            isnothing(mod) ? location : string(mod, " ", location),
            frame.inlined ? " [inlined]" : "",
        ),
        Base.find_source_file(expanduser(file)),
        frame.line,
        string(frame.func),
        isnothing(mod) ? nothing : string(mod),
        frame.inlined,
    )
end

"""
The call signature of a frame, as Julia prints it after the frame number, e.g.
`sqrt(x::Int64)`. `show_spec_linfo` is what `Base.show_backtrace` itself uses; should it
ever go away we simply lose the argument types.
"""
function frame_signature(frame::StackTraces.StackFrame)
    isdefined(StackTraces, :show_spec_linfo) || return string(frame.func)
    return sprint(StackTraces.show_spec_linfo, frame)
end

"Textual rendering of a [`TraceError`](@ref), close to what Julia would print."
function preview_text(trace::TraceError)
    isempty(trace.frames) && return trace.header
    return join([trace.header, "Stacktrace:", (f.text for f in trace.frames)...], '\n')
end

"""
    truncate_trace(trace::TraceError) -> TraceError

Drop the machinery frames that TestPicker and Julia's file loader add below the code
being tested.

The text equivalent, [`truncate_backtrace`](@ref), has to recognize that boundary from
what Julia printed; here the frames tell us which module and file they come from, so the
cutoff holds wherever TestPicker happens to be installed and whatever signature the
`include` of the day has.

Everything from TestPicker's own topmost frame downwards goes (that is TestPicker itself
and whoever called it), and so does the run of loader frames just above it. Loader frames
are only stripped from that run, so a test that calls `eval` or `include` of its own keeps
the frames that surround it.
"""
function truncate_trace(trace::TraceError)
    boundary = findfirst(is_testpicker_frame, trace.frames)
    frames = isnothing(boundary) ? trace.frames : trace.frames[1:(boundary - 1)]
    cutoff = findlast(!is_loader_frame, frames)
    isnothing(cutoff) || (frames = frames[1:cutoff])
    return TraceError(trace.header, frames)
end

"""
The `Base`/`Core` entry points through which TestPicker gets the tests evaluated. They sit
at the bottom of every backtrace we capture and never say anything about the failure.
"""
const LOADER_FUNCS = Set([
    "eval",
    "include",
    "_include",
    "include_string",
    "_include_dependency",
    "_include_dependency!",
    "IncludeInto",
    "exec_options",
    "_start",
])

function is_loader_frame(frame::TraceFrame)
    frame.mod in ("Base", "Core") || return false
    return base_name(frame.func) in LOADER_FUNCS
end

"Name of a function without the `#name#123` decoration keyword methods and the like carry."
base_name(func::AbstractString) = String(first(eachsplit(lstrip(func, '#'), '#')))

"Whether a frame comes from TestPicker itself."
function is_testpicker_frame(frame::TraceFrame)
    frame.mod == string(@__MODULE__) && return true
    # Inlined frames and top-level scopes carry no module, but still know their file.
    isnothing(frame.file) && return false
    return startswith(normpath(frame.file), testpicker_src_dir())
end

testpicker_src_dir() = normpath(joinpath(pkgdir(@__MODULE__), "src"))

"""
    drop_test_frames(trace::TraceError) -> TraceError

Remove the frames of the `Test` standard library, which only ever show the internals of
`@test` and `@testset`. Frames keep the number Julia gave them, so the gaps show where the
machinery was.
"""
function drop_test_frames(trace::TraceError)
    return TraceError(trace.header, filter(!is_test_frame, trace.frames))
end

function is_test_frame(frame::TraceFrame)
    isnothing(frame.file) && return false
    return !isnothing(match(r"stdlib[/\\]v[\d.]+[/\\]Test[/\\]src[/\\]", frame.file))
end
