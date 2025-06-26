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

# Arguments
- `repl::AbstractREPL`: The REPL instance to modify

# Side Effects
- Adds a new test mode to the REPL interface
- Modifies the main mode's keymap to include the trigger
- Sets up mode switching behavior and key bindings

# Notes
The test mode supports:
- Standard REPL features (history, search, etc.)
- Custom test commands and query parsing
- Seamless switching between main and test modes

# See also
[`create_repl_test_mode`](@ref)
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
    create_repl_test_mode(repl::AbstractREPL, main::LineEdit.Prompt) -> LineEdit.Prompt

Create a new REPL mode specifically for test operations.

Constructs a custom REPL prompt mode that handles test-specific commands and provides
an isolated interface for TestPicker operations. The mode includes proper history
support, key bindings, and command processing.

# Arguments
- `repl::AbstractREPL`: The REPL instance to create the mode for
- `main::LineEdit.Prompt`: The main REPL mode to inherit settings from

# Returns
- `LineEdit.Prompt`: The configured test mode prompt ready for use

# Features
- Custom prompt with magenta coloring (if supported)
- Sticky mode behavior for continued test operations
- Integrated history and search functionality
- Error handling for test execution failures
- Automatic return to main mode when appropriate

# See also
[`init_test_repl_mode`](@ref), [`test_mode_do_cmd`](@ref)
"""
function create_repl_test_mode(repl::AbstractREPL, main::LineEdit.Prompt)
    test_mode = LineEdit.Prompt(
        test_mode_prompt;
        prompt_prefix=repl.options.hascolor ? Base.text_colors[:magenta] : "",
        prompt_suffix="",
        sticky=true,
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
            e isa TestSetException ||
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

    _, skeymap = LineEdit.setup_search_keymap(hp)
    _, prefix_keymap = LineEdit.setup_prefix_keymap(hp, test_mode)

    # Check if the expression is incomplete, and, if so, request for another line.
    test_mode.on_enter = REPL.return_callback
    # We want to support all the default keymap prefixes.
    mk = REPL.mode_keymap(main)

    test_mode_keymaps = Dict{Any,Any}[
        skeymap,
        mk,
        prefix_keymap,
        LineEdit.history_keymap,
        LineEdit.default_keymap,
        LineEdit.escape_defaults,
    ]

    test_mode.keymap_dict = LineEdit.keymap(test_mode_keymaps)

    return test_mode
end

"""
    QueryType

Enumeration of different types of test queries supported by the test REPL mode.

# Values
- `TestFileQuery`: Query for running tests from specific files
- `TestsetQuery`: Query for running specific test sets (format: "file:testset")
- `LatestEval`: Re-run the most recently evaluated tests (triggered by "-")
- `InspectResults`: View test results visualization (triggered by "?")
- `UnmatchedQuery`: Query that couldn't be parsed or is invalid
"""
@enum QueryType TestFileQuery TestsetQuery LatestEval InspectResults UnmatchedQuery

"""
    identify_query(input::AbstractString) -> (QueryType, Tuple)

Parse user input in test mode and identify the type of operation requested.

Analyzes the input string to determine what kind of test operation the user wants
to perform and extracts the relevant parameters for that operation.

# Arguments
- `input::AbstractString`: The raw input from the test mode REPL

# Returns
- `Tuple{QueryType, Tuple}`: The query type and associated parameters

# Query Formats
- `"-"`: Re-run latest evaluation (returns `LatestEval` with stored tests)
- `"?"`: Inspect test results (returns `InspectResults` with empty tuple)  
- `"file:testset"`: Run specific test set (returns `TestsetQuery` with file and testset)
- `"filename"`: Run tests from file (returns `TestFileQuery` with filename and empty testset)

# Examples
```julia
identify_query("test_math.jl")           # (TestFileQuery, ("test_math.jl", ""))
identify_query("test_math.jl:addition")  # (TestsetQuery, ("test_math.jl", "addition"))
identify_query("-")                      # (LatestEval, <previous_tests>)
identify_query("?")                      # (InspectResults, ())
```

# Error Handling
- Returns `UnmatchedQuery` for inputs that cannot be parsed
- Handles case where no previous evaluation exists for "-" command

# See also
[`QueryType`](@ref), [`test_mode_do_cmd`](@ref)
"""
function identify_query(input::AbstractString)
    if strip(input) == "-"
        if isnothing(LATEST_EVAL[])
            @error "No test evaluated yet (reset with every session)."
            UnmatchedQuery, ()
        else
            LatestEval, LATEST_EVAL[]
        end
    elseif strip(input) == "?"
        InspectResults, ()
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

# Arguments
- `repl::AbstractREPL`: The REPL instance for result visualization
- `input::String`: The command string entered by the user

# Commands Supported
- File queries: Run tests from matching files using fuzzy search
- Testset queries: Run specific test sets using file:testset syntax
- Latest evaluation: Re-run previously executed tests with "-"
- Result inspection: View test results with "?"

# Side Effects
- May execute test code and modify package environments
- Updates the latest evaluation cache
- Can display test results in the REPL
- Outputs informational messages and errors

# Error Handling
- Catches and reports `TestSetException` errors from test execution
- Provides warning for non-interactive usage
- Handles unrecognized query formats

# Examples
```julia
# In test mode:
# "math"              # Run tests from files matching "math"
# "test_calc.jl:add"  # Run "add" testset from test_calc.jl
# "-"                 # Re-run last tests
# "?"                 # View test results
```

# See also
[`identify_query`](@ref), [`fzf_testfile`](@ref), [`fzf_testblock`](@ref), [`visualize_test_results`](@ref)
"""
function test_mode_do_cmd(repl::AbstractREPL, input::String)
    if !isinteractive() && get(ENV, "PRINT_REPL_WARNING", true)
        @warn "The test mode is intended for interaction use only, and cannot not be used from scripts."
    end

    test_type, inputs = identify_query(input)

    @debug "Running $(test_type) with inputs $(inputs...)"

    if test_type == TestFileQuery
        fzf_testfile(first(inputs))
    elseif test_type == TestsetQuery
        fzf_testblock(INTERFACES, inputs...)
    elseif test_type == LatestEval
        pkg = current_pkg()
        clean_results_file(pkg)
        for expr in inputs
            eval_in_module(expr, pkg)
        end
    elseif test_type == InspectResults
        visualize_test_results(repl)
    else
        error("Query $(input) could not be interpreted.")
    end

    return nothing
end
