using Test
using TestPicker

@testset "truncate_backtrace" begin
    fake_bt = """
Stacktrace:
 [1] user_func()
    @ UserModule /home/user/project/src/foo.jl:10
 [2] another_user_func()
    @ UserModule /home/user/project/src/bar.jl:20
 [3] include(mod::Module, _path::String)
    @ Base ./Base.jl:495
 [4] include(x::String)
    @ Main.var"##TestPicker#226" ./none:0
 [5] run_testfile(file::String)
    @ TestPicker /home/theo/.julia/dev/TestPicker/src/testfile.jl:205"""

    result = TestPicker.truncate_backtrace(fake_bt)

    @test contains(result, "user_func")
    @test contains(result, "another_user_func")
    @test !contains(result, "include(mod::Module")
    @test !contains(result, "run_testfile")
    @test contains(result, "Stacktrace:")
end

@testset "truncate_backtrace - top-level scope in TestPicker src" begin
    fake_bt = """
Stacktrace:
 [1] user_func()
    @ UserModule /home/user/project/src/foo.jl:10
 [2] another_user_func()
    @ UserModule /home/user/project/src/bar.jl:20
 [3] top-level scope
    @ ~/.julia/dev/TestPicker/src/testblock.jl:229
 [4] eval_in_module(::TestPicker.EvalTest)
    @ TestPicker ~/.julia/dev/TestPicker/src/eval.jl:112"""

    result = TestPicker.truncate_backtrace(fake_bt)

    @test contains(result, "user_func")
    @test contains(result, "another_user_func")
    @test !contains(result, "top-level scope")
    @test !contains(result, "eval_in_module")
end

@testset "truncate_backtrace - top-level scope in TestPicker src (Windows path)" begin
    fake_bt = """
Stacktrace:
 [1] user_func()
    @ UserModule /home/user/project/src/foo.jl:10
 [2] another_user_func()
    @ UserModule /home/user/project/src/bar.jl:20
 [3] top-level scope
    @ C:\\Users\\user\\.julia\\dev\\TestPicker\\src\\testblock.jl:229
 [4] eval_in_module(::TestPicker.EvalTest)
    @ TestPicker C:\\Users\\user\\.julia\\dev\\TestPicker\\src\\eval.jl:112"""

    result = TestPicker.truncate_backtrace(fake_bt)

    @test contains(result, "user_func")
    @test contains(result, "another_user_func")
    @test !contains(result, "top-level scope")
    @test !contains(result, "eval_in_module")
end

@testset "truncate_backtrace - no include boundary" begin
    fake_bt = """
Stacktrace:
 [1] foo()
    @ Bar /some/file.jl:1
 [2] baz()
    @ Bar /some/other.jl:2"""

    result = TestPicker.truncate_backtrace(fake_bt)
    # No truncation point found, returns cleaned string unchanged
    @test contains(result, "foo")
    @test contains(result, "baz")
end

@testset "truncate_backtrace - ANSI codes stripped" begin
    ansi_reset = "\e[0m"
    ansi_blue = "\e[34m"
    fake_bt = """
$(ansi_blue)Stacktrace:$(ansi_reset)
 [1] $(ansi_blue)user_func$(ansi_reset)()
    @ UserModule /home/user/project/src/foo.jl:10
 [2] include(mod::Module, _path::String)
    @ Base ./Base.jl:495"""

    result = TestPicker.truncate_backtrace(fake_bt)
    @test contains(result, "user_func")
    @test !contains(result, "\e[")
end

@testset "truncate_backtrace - no stack frames" begin
    fake_bt = "Some error with no stack"
    result = TestPicker.truncate_backtrace(fake_bt)
    @test result == fake_bt
end

@testset "correct_testset_ancestor_line" begin
    lines = [
        "using Test",              # 1
        "",                        # 2
        "@testset \"outer\" begin", # 3
        "    proposal = 1",        # 4
        "",                        # 5
        "    @testset \"inner\" begin", # 6
        "        @test proposal == 1", # 7
        "    end",                 # 8
        "end",                     # 9
    ]

    # Julia's mis-attributed ancestor frame: reported line is the first statement
    # right after a `@testset` header, so it gets snapped up to the header itself.
    @test TestPicker.correct_testset_ancestor_line(lines, 4) == 3
    @test TestPicker.correct_testset_ancestor_line(lines, 7) == 6

    # Lines not directly preceded by a `@testset` header are left untouched.
    @test TestPicker.correct_testset_ancestor_line(lines, 8) == 8
    @test TestPicker.correct_testset_ancestor_line(lines, 1) == 1

    # Out-of-range line numbers are returned unchanged rather than erroring.
    @test TestPicker.correct_testset_ancestor_line(lines, 0) == 0
    @test TestPicker.correct_testset_ancestor_line(lines, 100) == 100
end
