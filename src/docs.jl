const HELP_TEXT = Markdown.md"""
# TestPicker Test Mode - Quick Reference

## Test File Selection
- `test> myfile` → Open fuzzy file picker with "myfile" as initial query
  - Use Tab for autocomplete on file names
  - Select file(s) in fzf and press Enter to run

## Test Block Selection
- `test> file:testset` → Open fuzzy testset picker
  - `file` → filter testsets by file name
  - `testset` → initial query for testset names
  - Select testset(s) in fzf and press Enter to run

## Special Commands
- `test> -` → Re-run the last test evaluation
- `test> @` → Inspect test results (errors/failures)
  - Press Enter to view stacktrace
  - Press Ctrl+e to edit test file
- `test> ?` → Show this help message

## Fuzzy Selection Mode
- **Enter** → Run selected file(s)/testset(s)
- **Ctrl+B** → Switch from file mode to testset mode
- **Tab/Shift+Tab** → Select/deselect multiple items
- **Ctrl+c / Escape** → Cancel selection

For more information, visit: https://theogf.dev/TestPicker.jl/
"""

"""
    print_test_docs() -> Nothing

Print a summary of available features and commands in test mode.

Displays a help message showing all the different ways to interact with
TestPicker's test REPL mode.
"""
function print_test_docs()
    show(stdout, MIME("text/plain"), HELP_TEXT)
    println()
    return nothing
end
