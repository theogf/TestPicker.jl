@testsnippet snippet begin
    a = true
end

@testmodule MyModule begin
    b = true
end

@testitem "Plain @testitem" begin
    @test true
end

@testitem "@testsnippet" setup = [snippet] begin
    @test a
end

@testitem "@testmodule" setup = [MyModule] begin
    @test MyModule.b
end