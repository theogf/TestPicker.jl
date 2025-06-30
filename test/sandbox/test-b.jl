@testset "Challenge for JuliaSyntax" begin
    a = true
    # @test a == [
    #     "fooskjdaskjhdskdja", "basadkashdalsdhar", "badalsdhasudz", "adaskdasgdasdggasgdsdf"
    # ]
end

@testitem "Foo" begin
    a = true
    @test a == true
    @test_nowarn TestPicker.INTERFACES
end
