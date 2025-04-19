const RESULT_PATH = first(mktemp())

"Separator used by `fzf` to distinguish the different data components."
separator() = "@@@@@"

"Utility function to adapt the size of the text width and line position."
function get_preview_dimension(terminal::Terminals.TextTerminal)
    return (;
        height=Terminals.height(terminal) - 8, width=Terminals.width(terminal) ÷ 2 - 4
    )
end

"""
This creates a loop on the latest evaluated test file.
It shows a list of the tests that errored and failed with a preview of their stacktrace.
You can edit the selected test with `Ctrl+e` or inspect the stacktrace for errored tests with `Enter`.
It is also possible to inspect the stacktrace as a list with a preview of the source when possible and
`Ctrl+e` edit the source of the current trace.
"""
function visualize_test_results(repl::AbstractREPL=Base.active_repl)
    editor_cmd = join(editor(), ' ')
    terminal = repl.t
    while true
        dims = get_preview_dimension(terminal)
        bat_preview = "echo {3} | $(get_bat_path()) --color=always --style=plain --terminal-width=$(dims.width)"
        fzf_args = [
            "--read0",
            "--multi",
            "--nth",
            "1",
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
        cmd = `$(fzf) $(fzf_args)`
        picked_val = chomp(
            read(
                pipeline(
                    Cmd(cmd; ignorestatus=true); stdin=IOBuffer(read(RESULT_PATH, String))
                ),
                String,
            ),
        )
        # If nothing is picked we exit the loop.
        isempty(picked_val) && return nothing

        # We fetch the data from the picked test.
        test, _, text = split(picked_val, separator())

        # We try to obtain the stack lines.
        stack_lines = split(text, '\n')
        start_stack = findfirst(x -> !isnothing(match(r"^ \[\d+\]", x)), stack_lines)
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

        cmd = `$(fzf()) $(fzf_args)`
        run(pipeline(Cmd(cmd; ignorestatus=true); stdin=IOBuffer(recut_vals)))
    end
end

"File names come with ansi characters and break stuff..."
function remove_ansi(s::AbstractString)
    reg = r"""(?P<col>(\x1b\[[;\d]*[A-Za-z])*)"""
    return replace(s, reg => "")
end

"We connect the error with the backtrace to be previewed."
function preview_content(test::Test.Error)
    return test.value * test.backtrace
end

function preview_content(test::Test.Fail)
    return test.data
end

"Obtain the source from the LineNumberNode."
function clean_source(source::LineNumberNode)
    return strip(strip(strip(string(source), '#'), '='))
end

function save_test_results(testset::Test.TestSetException)
    error_content = map(testset.errors_and_fails) do test
        join([test.orig_expr, clean_source(test.source), preview_content(test)], separator())
    end
    return write(RESULT_PATH, join(error_content, '\0'))
end
