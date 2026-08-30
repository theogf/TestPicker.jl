"""
    current_pkg() -> PackageSpec

Get the current package specification from the active Pkg environment.

This is a more flexible version of `current_pkg_name` from `TestEnv` that returns
the full `PackageSpec` object rather than just the package name. This provides
access to additional package metadata needed by TestPicker.
"""
function current_pkg()
    ctx = Context()
    ctx.env.pkg === nothing &&
        throw(TestEnvError("trying to activate test environment of an unnamed project"))
    return ctx.env.pkg
end

"""
    current_pkg_or_nothing() -> Union{Nothing,PackageSpec}

Same as [`current_pkg`](@ref) but returns `nothing` instead of throwing when the active
environment is not a package, e.g. when inspecting an error from a plain environment.
"""
function current_pkg_or_nothing()
    return try
        current_pkg()
    catch
        nothing
    end
end
