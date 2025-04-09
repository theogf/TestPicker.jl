"""
More flexible version of `current_pkg_name` from `TestEnv`.
"""
function current_pkg()
    ctx = Context()
    ctx.env.pkg === nothing &&
        throw(TestEnvError("trying to activate test environment of an unnamed project"))
    return ctx.env.pkg
end
