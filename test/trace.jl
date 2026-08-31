using Test
using TestPicker
using TestPicker: TraceError, TraceFrame, TestResultEntry
using TestPicker: trace_error, truncate_trace, group_frames, preview_text, fzf_input
using JSON

boom(x) = sqrt(x)
exception_stack() =
    try
        boom(-1)
    catch
        Base.current_exceptions()
    end

@testset "trace_error from a real backtrace" begin
    trace = trace_error(exception_stack())
    @test contains(TestPicker.remove_ansi(trace.header), "DomainError")
    @test !isempty(trace.frames)

    top = first(trace.frames)
    @test top.func == "throw_complex_domainerror"
    @test top.mod == "Base.Math"
    # The file is resolved to something that exists, not to what Julia would print.
    @test isfile(top.file)
    @test top.line > 0
    # Frames are rendered the way Julia prints them.
    @test startswith(top.text, " [1] throw_complex_domainerror(")
    @test contains(top.text, "\n   @ Base.Math ./math.jl:$(top.line)")

    # This file's own frame carries its real path, whatever Julia chose to print.
    ours = only(filter(f -> f.func == "boom", trace.frames))
    @test ours.file == @__FILE__
end

@testset "trace_error from printed text" begin
    text = """
    DomainError with -1.0:
    Stacktrace:
     [1] user_func()
       @ UserModule /home/user/project/src/foo.jl:10
     [2] other()
       @ UserModule /home/user/project/src/bar.jl:20"""
    trace = trace_error(text)
    @test trace.header == "DomainError with -1.0:"
    @test length(trace.frames) == 2
    @test first(trace.frames).line == 10
    @test last(trace.frames).line == 20
    # Absolute paths are kept as they are, `Base.find_source_file` does not check them.
    @test first(trace.frames).file == "/home/user/project/src/foo.jl"
    # A location Julia prints in a form the regex cannot read leaves no source behind.
    @test isnothing(
        only(trace_error("boom\nStacktrace:\n [1] f()\n   @ Main REPL[1]:1").frames).file
    )

    # Text without any frame yields a trace the viewer knows to skip.
    empty = trace_error("ERROR: something went wrong")
    @test isempty(empty.frames)
    @test empty.header == "ERROR: something went wrong"
end

@testset "both parsers agree on the same error" begin
    stack = exception_stack()
    raw = trace_error(stack)
    printed = trace_error(sprint(Base.display_error, stack; context=(:color => false)))
    # The printed backtrace hides some loader frames, so it only ever has fewer.
    @test length(printed.frames) <= length(raw.frames)
    common = min(length(printed.frames), 5)
    @test [f.line for f in printed.frames[1:common]] == [f.line for f in raw.frames[1:common]]
    @test [f.file for f in printed.frames[1:common]] == [f.file for f in raw.frames[1:common]]
end

@testset "truncate_trace" begin
    src = joinpath(pkgdir(TestPicker), "src", "eval.jl")
    user(f, line) = TraceFrame(" [x] $(f)", @__FILE__, line, f, "Main", false)
    loader(f) = TraceFrame(" [x] $(f)", nothing, 0, f, "Base", false)
    testpicker = TraceFrame(
        " [x] eval_in_module", src, 1, "eval_in_module", "TestPicker", false
    )
    caller = TraceFrame(
        " [x] top-level scope", @__FILE__, 99, "top-level scope", nothing, false
    )

    frames = [
        user("a", 1), user("b", 2), loader("eval"), loader("include"), testpicker, caller
    ]
    kept = truncate_trace(TraceError("boom", frames)).frames
    @test [f.func for f in kept] == ["a", "b"]

    # A loader frame with user code below it is kept: only the trailing run goes.
    frames = [user("a", 1), loader("eval"), user("b", 2), loader("include"), testpicker]
    @test [f.func for f in truncate_trace(TraceError("boom", frames)).frames] == ["a", "eval", "b"]

    # Nothing of ours in the trace: nothing to cut.
    frames = [user("a", 1), user("b", 2)]
    @test length(truncate_trace(TraceError("boom", frames)).frames) == 2

    # A TestPicker frame is recognized from its file even without a module.
    anonymous = TraceFrame(
        " [x] top-level scope", src, 5, "top-level scope", nothing, false
    )
    @test isempty(truncate_trace(TraceError("boom", [anonymous])).frames)
end

@testset "preview_text" begin
    trace = trace_error(exception_stack())
    text = TestPicker.remove_ansi(preview_text(trace))
    @test contains(text, "DomainError")
    @test contains(text, "Stacktrace:")
    @test contains(text, "[1] throw_complex_domainerror")
    @test preview_text(TraceError("no frames", TraceFrame[])) == "no frames"
end

@testset "JSON round trip" begin
    entry = TestResultEntry(
        "a == b",
        "/tmp/x.jl:3",
        "preview\nover\nlines",
        "ctx",
        trace_error(exception_stack()),
    )
    back = JSON.parse(JSON.json(entry), TestResultEntry)
    @test back.list_view == entry.list_view
    @test back.preview == entry.preview
    @test back.trace.header == entry.trace.header
    @test length(back.trace.frames) == length(entry.trace.frames)
    @test first(back.trace.frames).file == first(entry.trace.frames).file
    @test first(back.trace.frames).inlined == first(entry.trace.frames).inlined

    # A failure has no trace at all, which has to survive the round trip as `null`.
    failed = TestResultEntry("a == b", "/tmp/x.jl:3", "preview", "ctx", nothing)
    @test isnothing(JSON.parse(JSON.json(failed), TestResultEntry).trace)
end

@testset "fzf records lead with the entry index" begin
    entries = [
        TestResultEntry("first", "/tmp/x.jl:1", "preview\nwith\nnewlines", "ctx", nothing),
        TestResultEntry("second", "/tmp/y.jl:2", "another", "ctx", nothing),
    ]
    records = split(fzf_input(entries), '\0')
    @test length(records) == 2
    # The index has to be readable from the head of the record, since the preview field
    # holds the newlines `fzf` separates its own output with.
    @test first(split(records[1], TestPicker.separator())) == "1"
    @test first(split(records[2], TestPicker.separator())) == "2"
    @test split(records[1], TestPicker.separator())[2] == "first"
end

@testset "printed_func" begin
    f = TestPicker.printed_func
    @test f(" [1] throw_complex_domainerror(x::Float64)\n   @ Base ./math.jl:33") ==
        "throw_complex_domainerror"
    @test f(" [3] macro expansion\n   @ ./Test.jl:1 [inlined]") == "macro expansion"
    @test f(" [1] top-level scope\n   @ ./a.jl:4") == "top-level scope"
    # A callable object has no name before its arguments, so we keep the whole call.
    @test f(" [9] (::Base.IncludeInto)(fname::String)\n   @ Base ./Base.jl:308") ==
        "(::Base.IncludeInto)(fname::String)"
    @test f("not a frame") == ""
end

@testset "repair_toplevel_lines" begin
    file = "/tmp/tests.jl"
    frame(func, line; inlined=false, f=file) = TraceFrame(
        " [x] $(func)\n   @ Main $(something(f, "?")):$(line)",
        f,
        line,
        func,
        nothing,
        inlined,
    )

    # The scope reports the last plain statement, the inlined macro frames the real line.
    frames = [
        frame("top-level scope", 4),
        frame("macro expansion", 1777; inlined=true, f="/julia/Test.jl"),
        frame("macro expansion", 6; inlined=true),
    ]
    repaired = TestPicker.repair_toplevel_lines(TraceError("boom", frames))
    @test first(repaired.frames).line == 6
    # The text follows, so the picker and the preview agree.
    @test contains(first(repaired.frames).text, "$(file):6")
    @test !contains(first(repaired.frames).text, "$(file):4")
    # The frames it was recovered from are untouched.
    @test last(repaired.frames).line == 6

    # The innermost invocation wins when the macros nest.
    frames = [
        frame("top-level scope", 4),
        frame("macro expansion", 6; inlined=true),
        frame("macro expansion", 7; inlined=true),
    ]
    @test first(TestPicker.repair_toplevel_lines(TraceError("boom", frames)).frames).line ==
        7

    # A function defined in the same file reports its own line and must be left alone.
    frames = [
        frame("g", 2),
        frame("top-level scope", 4),
        frame("macro expansion", 5; inlined=true),
    ]
    repaired = TestPicker.repair_toplevel_lines(TraceError("boom", frames)).frames
    @test [f.line for f in repaired] == [2, 5, 5]

    # Nothing to recover from: the run of inlined frames stops before any same-file frame.
    frames = [
        frame("top-level scope", 4),
        frame("f", 9),
        frame("macro expansion", 6; inlined=true),
    ]
    @test first(TestPicker.repair_toplevel_lines(TraceError("boom", frames)).frames).line ==
        4

    # A scope with no source at all is left as it is.
    frames = [frame("top-level scope", 1; f=nothing)]
    @test first(TestPicker.repair_toplevel_lines(TraceError("boom", frames)).frames).line ==
        1
end

@testset "drop_test_frames" begin
    keep = TraceFrame(" [1] f", "/home/me/pkg/test/runtests.jl", 3, "f", nothing, false)
    stdlib = TraceFrame(
        " [2] macro expansion",
        "/usr/share/julia/stdlib/v1.12/Test/src/Test.jl",
        1777,
        "macro expansion",
        nothing,
        true,
    )
    # Julia reports the stdlib from wherever it was built, so the tail of the path decides.
    built = TraceFrame(
        " [3] macro expansion",
        "/cache/build/julia-ci/usr/share/julia/stdlib/v1.12/Test/src/Test.jl",
        677,
        "macro expansion",
        nothing,
        true,
    )
    windows = TraceFrame(
        " [4] macro expansion",
        "C:\\julia\\share\\julia\\stdlib\\v1.12\\Test\\src\\Test.jl",
        1,
        "macro expansion",
        nothing,
        true,
    )
    nofile = TraceFrame(" [5] f", nothing, 0, "f", nothing, false)
    dropped = TestPicker.drop_test_frames(
        TraceError("boom", [keep, stdlib, built, windows, nofile])
    )
    @test dropped.frames == [keep, nofile]
    # The numbers Julia gave the kept frames stay, so the gaps show what went.
    @test contains(first(dropped.frames).text, "[1]")
    @test contains(last(dropped.frames).text, "[5]")
end
