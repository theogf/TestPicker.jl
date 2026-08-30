using Test
using TestPicker
using TestPicker: error_text, last_exception, inspect_error

@testset "error_text" begin
    stack = try
        sqrt(-1)
    catch
        Base.current_exceptions()
    end
    text = TestPicker.remove_ansi(error_text(stack))
    @test contains(text, "DomainError")
    @test contains(text, "Stacktrace:")
    # The frames are formatted the way the stacktrace viewer expects them.
    @test !isnothing(match(r"^\s*\[1\]"m, text))

    exception, backtrace = stack[1]
    text = TestPicker.remove_ansi(error_text(exception, backtrace))
    @test contains(text, "DomainError")
    @test contains(text, "Stacktrace:")

    # Without backtrace we only get the error message.
    text = TestPicker.remove_ansi(error_text(exception, []))
    @test contains(text, "DomainError")
    @test !contains(text, "Stacktrace:")
end

@testset "last_exception" begin
    # `err` is `nothing` until the REPL stores an exception stack in it.
    @test isnothing(last_exception())
end

@testset "inspect_error without stacktrace" begin
    @test_logs (:warn,) match_mode = :any begin
        @test isnothing(inspect_error("ERROR: an error without any stacktrace"))
    end
    @test_logs (:warn,) match_mode = :any begin
        @test isnothing(inspect_error(Base.ExceptionStack(Any[])))
    end
    @test_logs (:warn,) match_mode = :any begin
        @test isnothing(inspect_error())
    end
end
