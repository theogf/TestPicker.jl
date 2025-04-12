using TestPicker
using Test
using TestPicker: create_repl_test_mode
using REPL: LineEdit

@testset "Building the REPL mode" begin
    repl = Base.active_repl
    test_mode = create_repl_test_mode(repl, repl.interface.modes[1])
    @test test_mode isa LineEdit.Prompt
    @test test_mode.prompt() == "test> "
    @test test_mode.on_done isa Function
end
