# Most of this code comes originally from TerminalPager.jl authored by robisbr under the MIT license.

test_mode_prompt() = "test> "

"Trigger key to get into test mode."
const TESTMODE_TRIGGER = '!'

"""
    init_test_repl_mode(repl::AbstractREPL) -> Nothing

Initialize and add test mode to the REPL interface.

Sets up a custom REPL mode for TestPicker that can be accessed by typing '!' at the
beginning of a line. The test mode provides specialized commands for running and
inspecting tests interactively.
"""
function init_test_repl_mode(repl::AbstractREPL)
    # Get the main REPL mode (julia prompt).
    main_mode = repl.interface.modes[1]

    # Create the pager mode.
    test_mode = create_repl_test_mode(repl, main_mode)

    # Add the new mode to the REPL interfaces.
    push!(repl.interface.modes, test_mode)

    # Assign `test_trigger` as the key map to switch to pager mode.
    keymap = Dict{Any,Any}(
        TESTMODE_TRIGGER => function (s, args...)
            # We must only switch to pager mode if `!` is typed at the beginning
            # of the line.
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, test_mode) do
                    LineEdit.state(s, test_mode).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s, TESTMODE_TRIGGER)
            end
        end
    )

    # Add the key map that initialize the pager mode to the default REPL key mappings.
    main_mode.keymap_dict = LineEdit.keymap_merge(main_mode.keymap_dict, keymap)

    return nothing
end

"""
    TestModeCompletionProvider

Completion provider for test mode that suggests test file names.
"""
struct TestModeCompletionProvider <: REPL.LineEdit.CompletionProvider end

"""
    complete_line(::TestModeCompletionProvider, s::LineEdit.PromptState; hint::Bool=false)

Provide completions based on available test file names (without paths), plus the
package-qualified names the pickers show when the active environment is a workspace.
"""
function REPL.complete_line(
    ::TestModeCompletionProvider, s::LineEdit.PromptState; hint::Bool=false
)
    partial = String(take!(copy(LineEdit.buffer(s))))

    # Don't complete if ':' is present (testset query mode)
    if contains(partial, ':')
        return (String[], partial, false)
    end

    # Try to get test files - if it fails, return empty completions
    try
        files = get_testfiles(current_pkgs())

        # Extract just the base file names (without path, but keep .jl extension), and the
        # labels themselves when they say more, i.e. when they name a package of a workspace.
        file_names = String[]
        for file in files
            push!(file_names, basename(file.name))
            file.label == file.name || push!(file_names, file.label)
        end
        unique!(file_names)

        # Filter completions based on partial input
        completions = filter(name -> startswith(name, partial), file_names)

        return (completions, partial, !isempty(completions))
    catch
        # If we can't get test files, return empty completions
        return (String[], partial, false)
    end
end

"""
    create_repl_test_mode(repl::AbstractREPL, main::LineEdit.Prompt) -> LineEdit.Prompt

Create a new REPL mode specifically for test operations.

Constructs a custom REPL prompt mode that handles test-specific commands and provides
an isolated interface for TestPicker operations. The mode includes proper history
support, key bindings, and command processing.
"""
function create_repl_test_mode(repl::AbstractREPL, main::LineEdit.Prompt)
    test_mode = LineEdit.Prompt(
        test_mode_prompt;
        prompt_prefix=repl.options.hascolor ? Base.text_colors[:magenta] : "",
        prompt_suffix="",
        sticky=true,
        complete=TestModeCompletionProvider(),
    )
    # This function is called when the user hits return after typing a command.
    test_mode.on_done = function (s, buf::IOBuffer, ok)
        ok || return REPL.transition(s, :abort)

        # Take the input command.
        input = String(take!(buf))
        REPL.reset(repl)

        # Process the input command inside the pager mode.
        try
            test_mode_do_cmd(repl, input)
        catch e
            e isa Union{TestSetException,TestPickerTestSetException} ||
                @error "Could not complete test picker action due to error:\n$(current_exceptions()))"
        end
        REPL.prepare_next(repl)
        REPL.reset_state(s)
        return s.current_mode.sticky || REPL.transition(s, main)
    end

    test_mode.repl = repl

    hp = main.hist
    hp.mode_mapping[:test] = test_mode
    test_mode.hist = hp

    _, prefix_keymap = LineEdit.setup_prefix_keymap(hp, test_mode)

    # Always submit on enter — test mode input is not Julia syntax.
    test_mode.on_enter = (s) -> true
    # We want to support all the default keymap prefixes.
    mk = REPL.mode_keymap(main)

    test_mode_keymaps = Dict{Any,Any}[
        mk,
        prefix_keymap,
        LineEdit.history_keymap,
        LineEdit.default_keymap,
        LineEdit.escape_defaults,
    ]

    # `setup_search_keymap` was removed in Julia 1.13; the ^R/^S history search
    # it provided is now built into `LineEdit.history_keymap` above.
    if isdefined(LineEdit, :setup_search_keymap)
        _, skeymap = LineEdit.setup_search_keymap(hp)
        pushfirst!(test_mode_keymaps, skeymap)
    end

    test_mode.keymap_dict = LineEdit.keymap(test_mode_keymaps)

    return test_mode
end

"""
    QueryType

Enumeration of different types of test queries supported by the test REPL mode.
"""
@enum QueryType TestFileQuery TestsetQuery TestModeDocs LatestEval InspectResults InspectError UnmatchedQuery

"""
    identify_query(input::AbstractString) -> (QueryType, Tuple)

Parse user input in test mode and identify the type of operation requested.

Analyzes the input string to determine what kind of test operation the user wants
to perform and extracts the relevant parameters for that operation.
"""
function identify_query(input::AbstractString)
    if strip(input) == "-"
        if isnothing(LATEST_EVAL[])
            @error "No test evaluated yet (reset with every session)."
            UnmatchedQuery, ()
        else
            LatestEval, LATEST_EVAL[]
        end
    elseif strip(input) == "@"
        InspectResults, ()
    elseif strip(input) == "@e"
        InspectError, ()
    elseif strip(input) == "?"
        TestModeDocs, ()
    else
        m = match(r"(.*):(.*)", input)
        if !isnothing(m)
            TestsetQuery, Tuple(m.captures)
        else
            TestFileQuery, (input, "")
        end
    end
end

"""
    test_mode_do_cmd(repl::AbstractREPL, input::String) -> Nothing

Execute test commands received in the test REPL mode.

Processes user input from the test mode, identifies the requested operation,
and dispatches to the appropriate test execution or inspection function.
"""
function test_mode_do_cmd(repl::AbstractREPL, input::String)
    if !isinteractive() && get(ENV, "PRINT_REPL_WARNING", true)
        @warn "The test mode is intended for interaction use only, and cannot not be used from scripts."
    end

    test_type, inputs = identify_query(input)

    @debug "Running $(test_type) with inputs $(inputs...)"

    if test_type == TestFileQuery
        fzf_testfile(first(inputs); interactive=true)
    elseif test_type == TestsetQuery
        fzf_testblock(INTERFACES, inputs...; interactive=true)
    elseif test_type == LatestEval
        # Each test knows its own package, which need not be a single one when the latest
        # selection spanned several packages of a workspace.
        foreach(clean_results_file, unique_pkgs(test.pkg for test in inputs))
        refreshed = filter(!isnothing, refresh_stale_test.(inputs))
        LATEST_EVAL[] = refreshed
        for test in refreshed
            eval_in_module(test)
        end
    elseif test_type == TestModeDocs
        print_test_docs()
    elseif test_type == InspectResults
        visualize_test_results(repl)
    elseif test_type == InspectError
        inspect_error(; repl)
    else
        error("Query $(input) could not be interpreted.")
    end

    return nothing
end
