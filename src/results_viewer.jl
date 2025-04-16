const RESULT_PATH = first(mktemp())
separator() = "~~~"
function load_testresults()
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
    val, text = split(picked_val, separator())
    lines = split(text, '\n')[3:end]
    traces = join.(Iterators.partition(lines, 2), '\n')
    enriched = map(traces) do trace
        @show path = match(r"(\S+\.jl):(\d+)", trace)
        if !isnothing(path)
            join([trace, remove_ansi.(path.captures)...], separator())
        else
            trace
        end
    end
    @show enriched[2]
    recut_vals = join(enriched, '\0')
    cmd = Cmd(
        String[
            "fzf",
            "--multi",
            "--read0",
            "--ansi",
            "--with-nth",
            "{1}",
            "--preview",
            "bat {2} --color=always --line-range={3}:",
            "-d",
            separator(),
        ],
    )
    return run(pipeline(Cmd(cmd; ignorestatus=true); stdin=IOBuffer(recut_vals)))

    # end

end

function remove_ansi(s::AbstractString)
    reg = r"""
    (?P<col>(\x1b     # literal ESC
    \[       # literal [
    [;\d]*   # zero or more digits or semicolons
    [A-Za-z] # a letter
    )*)
    (?P<name>.*)
    """
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
