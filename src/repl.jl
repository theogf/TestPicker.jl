# Most of this code comes originally from TerminalPager.jl authored by robisbr under the MIT license.

test_mode_prompt() = "test> "

test_trigger = '!'

# Initialize the pager mode in the `repl`.
function init_test_repl_mode(repl::AbstractREPL)
    # Get the main REPL mode (julia prompt).
    main_mode = repl.interface.modes[1]

    # Create the pager mode.
    test_mode = create_test_repl_mode(repl, main_mode)

    # Add the new mode to the REPL interfaces.
    push!(repl.interface.modes, test_mode)

    # Assign `test_trigger` as the key map to switch to pager mode.
    keymap = Dict{Any,Any}(
        test_trigger => function (s, args...)
            # We must only switch to pager mode if `!` is typed at the beginning
            # of the line.
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, test_mode) do
                    LineEdit.state(s, test_mode).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s, test_trigger)
            end
        end
    )

    # Add the key map that initialize the pager mode to the default REPL key mappings.
    main_mode.keymap_dict = LineEdit.keymap_merge(main_mode.keymap_dict, keymap)

    return nothing
end

function create_test_repl_mode(repl::AbstractREPL, main::LineEdit.Prompt)
    test_mode = LineEdit.Prompt(
        test_mode_prompt;
        complete=REPL.REPLCompletionProvider(),
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

    # Check if the expression is incomplete, and, if so, request for another line.
    test_mode.on_enter = REPL.return_callback
    # We want to support all the default keymap prefixes.
    mk = REPL.mode_keymap(main)

    test_mode_keymaps = Dict{Any,Any}[mk, LineEdit.default_keymap, LineEdit.escape_defaults]

    test_mode.keymap_dict = LineEdit.keymap(test_mode_keymaps)

    return test_mode
end

@enum TestType TestFile TestSet Unmatched

function identify_query(input::String)
    m = match(r"(.*):(.*)", input)
    if !isnothing(m)
        TestSet, Tuple(m.captures)
    else
        TestFile, (input, "")
    end
end

# Execute the actions when a command has been received in the REPL mode `test`. `repl`
# must be the active REPL, and `input` is a string with the command.
function test_mode_do_cmd(repl::AbstractREPL, input::String)
    if !isinteractive() && !PRINTED_REPL_WARNING[]
        @warn "The test mode is intended for interaction use only, and cannot not be used from scripts."
        PRINTED_REPL_WARNING[] = true
    end

    test_type, inputs = identify_query(input)

    @debug "Running $(test_type) with inputs $(inputs...)"

    if test_type == TestFile
        find_and_run_test_file(first(inputs))
    elseif test_type == TestSet
        select_and_run_testset(inputs...)
    end

    return nothing
end
