const RESULT_PATH = first(mktemp())
separator() = "~~~"
function load_testresults(repl::AbstractREPL=Base.active_repl)
    # fzf() do fzf_exe
    cmd = Cmd(
        String[
            # fzf_exe,
            "fzf",
            "--read0",
            "--multi",
            # "--nth=1",
            "--with-nth",
            "{1}",
            # "--accept-nth",
            # "{1}",
            "-d",
            "$(separator())",
            "--preview",
            "echo {2}",
        ],
    )
    # end
    picked_val = chomp(
        read(pipeline(cmd; stdin=IOBuffer(read(RESULT_PATH, String))), String)
    )
    terminal = repl.t
    ter_height = Terminals.height(terminal) - 8
    pad = ter_height ÷ 2
    test, text = split(picked_val, separator())

    stack_lines = split(text, '\n')
    start_stack = findfirst(x -> !isnothing(match(r"^ \[\d+\]", x)), stack_lines)
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
    editor = ENV["EDITOR"]
    recut_vals = join(enriched, '\0')
    cmd = Cmd(
        String[
            "fzf",
            "--multi",
            "--read0",
            "--ansi",
            "--header",
            "$(test)",
            "--header-label",
            "test",
            "--with-nth",
            "{1}",
            "--preview",
            "bat --line-range {4}:{5} --highlight-line {3} --color=always {2}",
            "--bind",
            "ctrl-o:execute($(editor) {2}:{3})",
            "-d",
            separator(),
        ],
    )
    return run(pipeline(Cmd(cmd; ignorestatus=true); stdin=IOBuffer(recut_vals)))

    # end

end

function remove_ansi(s::AbstractString)
    reg = r"""(?P<col>(\x1b\[[;\d]*[A-Za-z])*)"""
    return replace(s, reg => "")
end

function preview_content(test::Test.Error)
    return test.value * test.backtrace
end

function preview_content(test::Test.Fail)
    return test.value
end

function save_test_results(testset::Test.TestSetException)
    error_content = map(testset.errors_and_fails) do test
        join([test.orig_expr, preview_content(test)], separator())
    end
    return write(RESULT_PATH, join(error_content, '\0'))
end
