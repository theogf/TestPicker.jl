using Test
using TestPicker
using TestPicker: trace_error, last_exception, inspect_error

@testset "inspect_error keeps the real backtrace" begin
    stack = try
        sqrt(-1)
    catch
        Base.current_exceptions()
    end
    # The exception never goes through text: the frames reach the viewer as they are.
    trace = TestPicker.trace_error(stack)
    @test contains(TestPicker.remove_ansi(trace.header), "DomainError")
    @test !isempty(trace.frames)
    @test first(trace.frames).func == "throw_complex_domainerror"

    exception, backtrace = stack[1]
    @test TestPicker.trace_error(exception, backtrace).frames == trace.frames
    # Without a backtrace there is nothing to explore, only a message.
    @test isempty(TestPicker.trace_error(exception, nothing).frames)
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
