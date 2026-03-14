const RESULT_PATH = mktempdir()

"Separator used by `fzf` to distinguish the different data components."
separator() = "@@@@@"

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
    results_path = pkg_results_path(pkg)
    if !isfile(results_path)
        @warn "No results found, results will not be available until you get failures or errors from your tests."
        return nothing
    end
    terminal = repl.t
    while true
        dims = get_preview_dimension(terminal)
        bat_preview = "echo -e {3} | $(get_bat_path()) --file-name {2} --language julia --style header,grid --color always --wrap character --strip-ansi always --terminal-width $(dims.width)"
        fzf_args = [
            "--read0",
            "--multi",
            "--nth",
            1,
            "--header",
            "Failed and errored tests",
            "--with-nth",
            "{1}",
            "-d",
            "$(separator())",
            "--preview",
            bat_preview,
            "--bind",
            "ctrl-e:execute($(editor_cmd) {2})",
        ]
        cmd_list = `$(fzf()) $(fzf_args)`
        picked_val = chomp(
            read(
                pipeline(
                    Cmd(cmd_list; ignorestatus=true);
                    stdin=IOBuffer(read(results_path, String)),
                ),
                String,
            ),
        )
        # If nothing is picked we exit the loop.
        isempty(picked_val) && return nothing

        # We fetch the data from the picked test.
        test, _, text, context = split(picked_val, separator())

        # We try to obtain the stack lines.
        stack_lines = split(text, '\n')
        start_stack = findfirst(x -> !isnothing(match(r"^\s*\[\d+\]", x)), stack_lines)
        # This happens for fail tests that don't have stacktraces.
        isnothing(start_stack) && continue

        # Some useful dimensions for our preview.
        dims = get_preview_dimension(terminal)
        pad = dims.height ÷ 2
        error = join(vcat(test, stack_lines[1:(start_stack - 2)]), '\n')
        traces = join.(Iterators.partition(stack_lines[start_stack:end], 2), '\n')
        enriched = map(traces) do trace
            path = match(r"(\S+\.jl):(\d+)", trace)
            if !isnothing(path)
                file_path, line = remove_ansi.(path.captures)
                line_int = Base.parse(Int, line)
                line_start = max(0, line_int - pad)
                line_end = line_int + pad
                source_path = Base.find_source_file(expanduser(file_path))
                join([trace, source_path, line, line_start, line_end], separator())
            else
                trace
            end
        end
        recut_vals = join(enriched, '\0')
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
        contains(first(frame), "include(mod::Module, _path::String)") ||
        (contains(first(frame), "top-level scope") && any(contains(l, "TestPicker/src/") for l in frame))
    cutoff_idx = findfirst(is_cutoff, frames)
    isnothing(cutoff_idx) && return join(vcat(header, frame_lines), '\n')
    kept_frames = frames[1:(cutoff_idx - 1)]
    return join(vcat(header, collect(Iterators.flatten(kept_frames))), '\n')
end

"We connect the error with the backtrace to be previewed."
function preview_content(test::Test.Error)
    return join((test.value, truncate_backtrace(string(test.backtrace))), '\n')
end

function preview_content(test::Test.Fail)
    return test.data
end

function context(t::TestInfo)
    return t.filename * (isempty(t.label) ? "" : " - $(t.label)")
end

"Obtain the source from the LineNumberNode."
function clean_source(source::LineNumberNode)
    return strip(strip(strip(string(source), '#'), '='))
end

function pkg_results_path(pkg::PackageSpec)
    mkpath(RESULT_PATH)
    return joinpath(RESULT_PATH, pkg.name * " - " * string(pkg.uuid) * ".log")
end

"This empty the file before appending new results."
function clean_results_file(pkg::PackageSpec)
    return write(pkg_results_path(pkg), "")
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
    path = pkg_results_path(pkg)
    error_content = map(testset.errors_and_fails) do test
        join(
            [
                list_view(test),
                clean_source(test.source),
                preview_content(test),
                context(testinfo),
            ],
            separator(),
        )
    end
    touch(path)
    open(path, "a+") do io
        iszero(filesize(path)) || write(io, '\0')
        write(io, join(error_content, '\0'))
    end
end
