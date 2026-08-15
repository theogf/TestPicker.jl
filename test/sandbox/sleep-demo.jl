using Test

# Manual fixture for eyeballing the live progress bar (`test> ` mode or
# `TestPicker.run_testfile`). Not run by the automated test suite, which only lists
# `test/sandbox` files rather than executing them wholesale, so its `sleep`s and its
# intentional failure/broken test don't affect CI.

# A loop: JuliaSyntax statically sees one `@test`, but it runs 4 times, demonstrating the
# progress bar growing past its initial prediction instead of finishing early.
@testset "warmup (undercounted)" begin
    for i in 1:4
        sleep(0.5)
        @test true
    end
end

# A mix of outcomes, to show the live Passed/Failed/Errored/Broken breakdown and the bar
# switching to red once a failure shows up.
@testset "mixed results" begin
    sleep(0.5)
    @test true
    sleep(0.5)
    @test_broken false
    sleep(0.5)
    @test false
    sleep(0.5)
    @test true
end
