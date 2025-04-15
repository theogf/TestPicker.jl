const SEPARATOR = "~~~"
separator() = "~~~"
function load_testresults()
    fzf() do fzf_exe
        cmd = Cmd(String[
            "fzf",
            "--read0",
            # "--nth=1",
            "--with-nth",
            "{1}",
            "-d",
            "$(separator())",
        ])
        run(pipeline(cmd; stdin=IOBuffer(read(RESULT_PATH, String))))
    end
end

const RESULT_PATH = first(mktemp())

function preview_content(test::Test.Error)
    return test.value * test.backtrace
end

function preview_content(test::Test.Fail)
    return test.value
end

function save_testresults(testset::Test.TestSetException)
    error_content = map(testset.errors_and_fails) do test
        join([test.orig_expr, preview_content(test)], separator())
    end
    return write(RESULT_PATH, join(error_content, '\0'))
end
