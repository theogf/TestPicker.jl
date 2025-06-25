# Most of this code comes originally from TerminalPager.jl authored by robisbr under the MIT license.

test_mode_prompt() = "test> "

"Trigger key to get into test mode."
const TESTMODE_TRIGGER = '!'

# Initialize the pager mode in the `repl`.
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

"Create an additional repl mode for testing to the given `repl`."
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

@enum QueryType TestFileQuery TestsetQuery LatestEval InspectResults UnmatchedQuery

"Identify the type of query based on the input."
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

# Execute the actions when a command has been received in the REPL mode `test`
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
