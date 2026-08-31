@static if isdefined(Base, :OncePerProcess)
    const RESULT_PATH = OncePerProcess{String}() do
        mktempdir(; prefix="TestPicker_")
    end
else
    # No `OncePerProcess` before 1.12, so `__init__` fills the reference instead.
    const RESULT_PATH_REF = Ref{String}()
    RESULT_PATH() = RESULT_PATH_REF[]
end

"Directory holding the per-package results files, created once per session, see issue #97."
RESULT_PATH

"Separator used by `fzf` to distinguish the different data components."
separator() = "@@@@@"

"""
    TestResultEntry

One failed or errored test, as stored in the results file.

`list_view`, `source` and `preview` are what the first picker displays, edits and previews,
`context` records where the test came from, and `trace` holds the structured stacktrace the
stacktrace viewer explores. `trace` is `nothing` for failures that have no stacktrace at
all, and is built from the real backtrace whenever TestPicker managed to capture one, see
[`trace_error`](@ref).
"""
struct TestResultEntry
    list_view::String
    source::String
    preview::String
    context::String
    trace::Union{Nothing,TraceError}
end

"Utility function to adapt the size of the text width and line position."
function get_preview_dimension(terminal::Terminals.TextTerminal=Base.active_repl.t)
    return (;
        height=Terminals.height(terminal) - 8, width=Terminals.width(terminal) ÷ 2 - 4
    )
end

"""
    visualize_test_results(repl::AbstractREPL=Base.active_repl, pkg::PackageSpec=current_pkg()) -> Nothing

Interactive visualization of test failures and errors using fzf interface.

Creates a loop-based interface for browsing test failures and errors from the most recent
test execution. Provides syntax-highlighted previews of stack traces and allows editing
of test files directly from the interface.
"""
function visualize_test_results(
    repl::AbstractREPL=Base.active_repl, pkg::PackageSpec=current_pkg()
)
    editor_cmd = join(editor(), ' ')
    entries = read_results(pkg)
    if isnothing(entries)
        @warn "No results found, results will not be available until you get failures or errors from your tests."
        return nothing
    end
    terminal = repl.t
    while true
        dims = get_preview_dimension(terminal)
        bat_preview = "echo -e {4} | $(get_bat_path()) --file-name {3} --language julia --style header,grid --color always --wrap character --strip-ansi always --terminal-width $(dims.width)"
        fzf_args = [
            "--read0",
            "--multi",
            "--nth",
            2,
            "--header",
            "Failed and errored tests",
            "--with-nth",
            "{2}",
            "-d",
            "$(separator())",
            "--preview",
            bat_preview,
            "--bind",
            "ctrl-e:execute($(editor_cmd) {3})",
        ]
        cmd_list = `$(fzf()) $(fzf_args)`
        picked_val = chomp(
            read(
                pipeline(
                    Cmd(cmd_list; ignorestatus=true); stdin=IOBuffer(fzf_input(entries))
                ),
                String,
            ),
        )
        # If nothing is picked we exit the loop.
        isempty(picked_val) && return nothing

        # The index comes first so that it survives the newlines the preview field holds:
        # `fzf` separates the records it prints with a newline of its own, which would make
        # any later field ambiguous. Only the first selection is inspected.
        entry = entries[Base.parse(Int, first(split(picked_val, separator())))]

        # Fail tests don't have a stacktrace to explore.
        isnothing(entry.trace) && continue
        visualize_stacktrace(entry.trace; title=entry.list_view, pkg, terminal, editor_cmd)
    end
end

"""
The `\\0`-separated, `separator()`-delimited records the first picker reads on its stdin.

The index of the entry leads the record: the preview field holds newlines, so no later
field can be recovered from what `fzf` prints back.
"""
function fzf_input(entries::AbstractVector{TestResultEntry})
    records = map(enumerate(entries)) do (i, entry)
        join([i, entry.list_view, entry.source, entry.preview], separator())
    end
    return join(records, '\0')
end

"""
    visualize_stacktrace(trace::TraceError; title, pkg, terminal, editor_cmd) -> Bool
    visualize_stacktrace(text::AbstractString; kwargs...) -> Bool

Interactive exploration of a stacktrace using `fzf`.

Every frame of `trace` is listed as an entry, with a preview of the corresponding source
file around the relevant line, and `Ctrl+e` opens that source in the editor. Given a
`String` instead, the text is parsed into a [`TraceError`](@ref) first, see
[`trace_error`](@ref).

`title` is prepended to the error message shown in the `fzf` header, `pkg` (when given) is
used to highlight the frames pointing to the package `src` (blue) and `test` (yellow)
directories.

Returns `false` when `trace` has no frame to show, `true` otherwise.
"""
function visualize_stacktrace(
    trace::TraceError;
    title::AbstractString="",
    pkg::Union{Nothing,PackageSpec}=nothing,
    terminal::Union{Nothing,Terminals.TextTerminal}=nothing,
    editor_cmd::Union{Nothing,AbstractString}=nothing,
)
    isempty(trace.frames) && return false

    # The remaining defaults are only resolved once we know we have something to show.
    terminal = @something terminal Base.active_repl.t
    editor_cmd = @something editor_cmd join(editor(), ' ')

    # Some useful dimensions for our preview.
    dims = get_preview_dimension(terminal)
    pad = dims.height ÷ 2
    error = isempty(title) ? trace.header : join([title, trace.header], '\n')
    recut_vals = join((fzf_record(frame, pad, pkg) for frame in trace.frames), '\0')
    bat_preview = "$(get_bat_path()) --line-range {4}:{5} --highlight-line {3} --color=always --terminal-width=$(dims.width) {2}"
    fzf_args = [
        "--multi", # Show multiple lines
        "--read0", # Separate lines with \0
        "--ansi", # Read ANSI characters
        "--header", # Show header in text
        "$(error)",
        "--with-nth",
        "{1}",
        "--preview",
        bat_preview,
        "--bind",
        "ctrl-e:execute($(editor_cmd) {2}:{3})",
        "-d",
        separator(),
    ]

    cmd_stacktrace = `$(fzf()) $(fzf_args)`
    run(pipeline(Cmd(cmd_stacktrace; ignorestatus=true); stdin=IOBuffer(recut_vals)))
    return true
end

function visualize_stacktrace(text::AbstractString; kwargs...)
    return visualize_stacktrace(trace_error(text); kwargs...)
end

"""
One `separator()`-delimited record for the stacktrace picker: the text to display, the
source to preview and edit, and the line range the preview should cover.

Frames of the current package are highlighted, in blue for `src` and yellow for `test`.
Frames without a source we could resolve only get their text, leaving the preview empty.
"""
function fzf_record(frame::TraceFrame, pad::Int, pkg::Union{Nothing,PackageSpec})
    isnothing(frame.file) && return frame.text
    line_start = max(0, frame.line - pad)
    line_end = frame.line + pad
    return join(
        [highlight(frame, pkg), frame.file, frame.line, line_start, line_end], separator()
    )
end

"Color a frame according to the directory of the current package it belongs to."
function highlight(frame::TraceFrame, pkg::Union{Nothing,PackageSpec})
    pkg_path = isnothing(pkg) ? nothing : pkg.path
    isnothing(pkg_path) && return frame.text
    file = normpath(frame.file)
    if startswith(file, normpath(joinpath(pkg_path, "src")))
        return "\e[1;34m$(frame.text)\e[0m"
    elseif startswith(file, normpath(joinpath(pkg_path, "test")))
        return "\e[1;33m$(frame.text)\e[0m"
    else
        return frame.text
    end
end

"File names come with ansi characters and break stuff..."
function remove_ansi(s::AbstractString)
    reg = r"""(?P<col>(\x1b\[[;\d]*[A-Za-z])*)"""
    return replace(s, reg => "")
end

function list_view(test::Test.Fail)
    return test.orig_expr
end

function list_view(test::Test.Error)
    if test.test_type == :nontest_error
        "Exception outside of @test"
    else
        test.orig_expr
    end
end

"Truncate stacktrace at the lowest frame referencing TestPicker."
function truncate_backtrace(backtrace_str::AbstractString)
    lines = split(remove_ansi(backtrace_str), '\n')
    start_idx = findfirst(x -> !isnothing(match(r"^\s*\[\d+\]", x)), lines)
    isnothing(start_idx) && return join(lines, '\n')
    header = lines[1:(start_idx - 1)]
    frame_lines = lines[start_idx:end]
    frames = collect(Iterators.partition(frame_lines, 2))
    # Two heuristics mark the boundary between user code and TestPicker's machinery:
    # 1. `include(mod::Module, _path::String)` — Base's file loader, called by TestPicker
    #    to load the user's test file into the evaluation module.
    # 2. `top-level scope` at a TestPicker src path — the top-level expression that
    #    TestPicker evaluates when running a test block (e.g. via testblock.jl).
    is_cutoff(frame) =
        contains(first(frame), "include(mod::Module, _path::String)") || (
            contains(first(frame), "top-level scope") &&
            any(occursin(r"TestPicker[/\\]src[/\\]", l) for l in frame)
        )
    cutoff_idx = findfirst(is_cutoff, frames)
    isnothing(cutoff_idx) && return join(vcat(header, frame_lines), '\n')
    kept_frames = frames[1:(cutoff_idx - 1)]
    return join(vcat(header, collect(Iterators.flatten(kept_frames))), '\n')
end

"Build the entry of a single failed or errored test."
function result_entry(
    result::Union{Test.Fail,Test.Error},
    testinfo::TestInfo,
    testset_path::AbstractVector{<:AbstractString}=String[],
    trace::Union{Nothing,TraceError}=nothing,
)
    # Without a captured backtrace we fall back on parsing what `Test` printed for us.
    # Both are `nothing` for a failure, which simply has no stacktrace to show.
    trace = isnothing(trace) ? result_trace(result) : trace
    preview = with_testset_path(preview_content(result, trace), testset_path)
    return TestResultEntry(
        list_view(result),
        clean_source(result.source),
        # `Test.Fail.data` is `Union{Nothing,String}`.
        something(preview, ""),
        context(testinfo, testset_path),
        trace,
    )
end

"Stacktrace of a result as recovered from the text `Test` stored, if it has one."
result_trace(::Test.Fail) = nothing
function result_trace(result::Test.Error)
    return drop_test_frames(trace_error(truncate_backtrace(string(result.backtrace))))
end

"We connect the error with the backtrace to be previewed."
function preview_content(result::Test.Error, trace::Union{Nothing,TraceError})
    isnothing(trace) && return result.value
    return join((result.value, preview_text(trace)), '\n')
end

preview_content(result::Test.Fail, ::Union{Nothing,TraceError}) = result.data

function context(t::TestInfo, testset_path::AbstractVector{<:AbstractString}=String[])
    base = t.filename * (isempty(t.label) ? "" : " - $(t.label)")
    return isempty(testset_path) ? base : base * " - " * join(testset_path, " > ")
end

"Obtain the source from the LineNumberNode."
function clean_source(source::LineNumberNode)
    return strip(strip(strip(string(source), '#'), '='))
end

function pkg_results_path(pkg::PackageSpec)
    # `mkpath` only guards against a /tmp sweeper removing the directory.
    path = mkpath(RESULT_PATH())
    return joinpath(path, pkg.name * " - " * string(pkg.uuid) * ".jsonl")
end

"This empty the file before appending new results."
function clean_results_file(pkg::PackageSpec)
    return write(pkg_results_path(pkg), "")
end

"""
Append entries to the package's results file.

Results are stored as JSON Lines, one [`TestResultEntry`](@ref) per line, so that a new run
can simply append to what is already there, the way the runs themselves accumulate.
"""
function write_results(path::AbstractString, entries::AbstractVector{TestResultEntry})
    open(touch(path), "a") do io
        for entry in entries
            println(io, JSON.json(entry))
        end
    end
end

"""
    read_results(pkg::PackageSpec) -> Union{Nothing,Vector{TestResultEntry}}

Read back the entries saved for `pkg`, or `nothing` when no results were ever saved.
"""
function read_results(pkg::PackageSpec)
    path = pkg_results_path(pkg)
    isfile(path) || return nothing
    return [JSON.parse(line, TestResultEntry) for line in eachline(path) if !isempty(line)]
end

"""
    save_test_results(testset::Test.TestSetException, testinfo::TestInfo, pkg::PackageSpec) -> Nothing

Save test failures and errors from a test set to the package's results file.

Processes a test set exception containing failed and errored tests, formats them
for display in the results viewer, and appends them to the package's results file.
Each test result includes the test description, source location, detailed error
information, and context.
"""
function save_test_results(
    testset::Test.TestSetException, testinfo::TestInfo, pkg::PackageSpec
)
    entries = map(test -> result_entry(test, testinfo), testset.errors_and_fails)
    return write_results(pkg_results_path(pkg), entries)
end

"""
Prefix a preview with the `@testset` nesting path it occurred under, if any.

`preview` may be `nothing` (`Test.Fail.data` is `Union{Nothing,String}`), matching how
`preview_content` is otherwise handled by `join`.
"""
function with_testset_path(preview, testset_path::AbstractVector{<:AbstractString})
    isempty(testset_path) && return preview
    return "@testset: $(join(testset_path, " > "))\n\n$(preview)"
end

"""
    save_test_results(testset::TestPickerTestSetException, testinfo::TestInfo, pkg::PackageSpec) -> Nothing

Like the `Test.TestSetException` method, but each failure also carries the `@testset`
nesting path it occurred under, shown at the top of the preview text, and the stacktrace
captured from the real backtrace when there was one.
"""
function save_test_results(
    testset::TestPickerTestSetException, testinfo::TestInfo, pkg::PackageSpec
)
    entries = map(testset.results) do (; testset_path, result, trace)
        result_entry(result, testinfo, testset_path, trace)
    end
    return write_results(pkg_results_path(pkg), entries)
end
