"""
    current_pkg() -> PackageSpec

Get the current package specification from the active Pkg environment.

This is a more flexible version of `current_pkg_name` from `TestEnv` that returns
the full `PackageSpec` object rather than just the package name. This provides
access to additional package metadata needed by TestPicker.

# Returns
- `PackageSpec`: The package specification for the current project

# Throws
- `TestEnvError`: If trying to activate test environment of an unnamed project

# Notes
The function examines the current Pkg context to determine the active package.
This is essential for TestPicker to understand which package's tests are being
executed and where to store results.
"""
function current_pkg()
    ctx = Context()
    ctx.env.pkg === nothing &&
        throw(TestEnvError("trying to activate test environment of an unnamed project"))
    return ctx.env.pkg
end
