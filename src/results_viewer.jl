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
        path = match(r"(\S+\.jl):(\d+)", trace)
        if !isnothing(path)
            file_path, line = remove_ansi.(path.captures)
            line = max(1, Base.parse(Int, line) - 2)
            source_path = @something(
                Base.find_source_file(file_path), expanduser(file_path)
            )
            @show file_path, source_path
            join([trace, source_path, line], separator())
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
            "bat --line-range={3}: --color=always {2}",
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
