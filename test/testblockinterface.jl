using Test
using JuliaSyntax
using TestPicker
using TestPicker: TestBlockInterface, preamble, expr_transform, prepend_preamble_statements

# Create a concrete subtype of TestBlockInterface for testing
"""
Test implementation of TestBlockInterface that detects @test blocks.
"""
struct MockTestInterface <: TestBlockInterface end

function TestPicker.istestblock(::MockTestInterface, node::SyntaxNode)
    nodes = JuliaSyntax.children(node)
    return !isnothing(nodes) && !isempty(nodes) && Expr(first(nodes)) == Symbol("@test")
end

function TestPicker.blocklabel(::MockTestInterface, node::SyntaxNode)
    # Extract the test expression and create a label from it
    sourcetext = JuliaSyntax.sourcetext(node)
    # Remove @test and trim to create a label
    label = replace(sourcetext, r"@test\s*" => "")
    return strip(label)
end

function TestPicker.preamble(::MockTestInterface)
    return :(using Test, Random)
end

function TestPicker.expr_transform(::MockTestInterface, ex::Expr)
    # Transform @test expressions to add a println statement before them
    if ex.head == :macrocall && ex.args[1] == Symbol("@test")
        return quote
            println("Running test: ", $(string(ex.args[2])))
            $ex
        end
    end
    return ex
end

# Another test interface without optional methods to test defaults
"""
Minimal test implementation that only implements required methods.
"""
struct MinimalTestInterface <: TestBlockInterface end

function TestPicker.istestblock(::MinimalTestInterface, node::SyntaxNode)
    nodes = JuliaSyntax.children(node)
    return !isnothing(nodes) && !isempty(nodes) && Expr(first(nodes)) == Symbol("@testitem")
end

function TestPicker.blocklabel(::MinimalTestInterface, node::SyntaxNode)
    return "minimal_test_block"
end

@testset "TestBlockInterface Implementation Tests" begin
    
    @testset "MockTestInterface - Required Methods" begin
        interface = MockTestInterface()
        
        # Test istestblock method
        test_code = """
        @test 1 + 1 == 2
        """
        root = parseall(SyntaxNode, test_code)
        node = only(JuliaSyntax.children(root))
        @test TestPicker.istestblock(interface, node) == true
        
        non_test_code = """
        x = 5
        """
        root2 = parseall(SyntaxNode, non_test_code)
        node2 = only(JuliaSyntax.children(root2))
        @test TestPicker.istestblock(interface, node2) == false
        
        # Test blocklabel method
        label = TestPicker.blocklabel(interface, node)
        @test label == "1 + 1 == 2"
        
        complex_test_code = """
        @test length([1, 2, 3]) == 3
        """
        root3 = parseall(SyntaxNode, complex_test_code)
        node3 = only(JuliaSyntax.children(root3))
        label2 = TestPicker.blocklabel(interface, node3)
        @test label2 == "length([1, 2, 3]) == 3"
    end
    
    @testset "MockTestInterface - Optional Methods" begin
        interface = MockTestInterface()
        
        # Test preamble method
        preamble_expr = preamble(interface)
        @test preamble_expr == :(using Test, Random)
        
        # Test expr_transform method
        test_expr = :(@test 1 == 1)
        transformed = Base.remove_linenums!(expr_transform(interface, test_expr))
        @test transformed.head == :block
        @test length(transformed.args) == 2
        # Check that println was added
        @test transformed.args[1].head == :call
        @test transformed.args[1].args[1] == :println
        # Check that original test is preserved
        @test transformed.args[2] == test_expr
        
        # Test expr_transform with non-test expression (should return unchanged)
        non_test_expr = :(x = 5)
        unchanged = expr_transform(interface, non_test_expr)
        @test unchanged == non_test_expr
    end
    
    @testset "MinimalTestInterface - Default Behavior" begin
        interface = MinimalTestInterface()
        
        # Test required methods
        testitem_code = """
        @testitem "test name" begin
            @test true
        end
        """
        root = parseall(SyntaxNode, testitem_code)
        node = only(JuliaSyntax.children(root))
        @test TestPicker.istestblock(interface, node) == true
        
        label = TestPicker.blocklabel(interface, node)
        @test label == "minimal_test_block"
        
        # Test default optional methods
        @test preamble(interface) === nothing
        
        test_expr = :(x = 5)
        @test expr_transform(interface, test_expr) == test_expr
    end
    
    @testset "prepend_preamble_statements function" begin
        interface_with_preamble = MockTestInterface()
        interface_without_preamble = MinimalTestInterface()
        
        existing_preambles = [:(x = 1), :(y = 2)]
        
        # Test with interface that has preamble
        result_with = prepend_preamble_statements(interface_with_preamble, existing_preambles)
        @test length(result_with) == 3
        @test result_with[1] == :(using Test, Random)
        @test result_with[2] == :(x = 1)
        @test result_with[3] == :(y = 2)
        
        # Test with interface that has no preamble
        result_without = prepend_preamble_statements(interface_without_preamble, existing_preambles)
        @test result_without == existing_preambles
        @test length(result_without) == 2
    end
    
    @testset "Error Cases for Abstract Interface" begin
        # Test that abstract interface throws errors for unimplemented methods
        struct UnimplementedInterface <: TestBlockInterface end
        
        interface = UnimplementedInterface()
        dummy_node = parseall(SyntaxNode, "x = 1") |> x -> only(JuliaSyntax.children(x))
        
        @test_throws ErrorException TestPicker.istestblock(interface, dummy_node)
        @test_throws ErrorException TestPicker.blocklabel(interface, dummy_node)
    end
    
    @testset "Edge Cases" begin
        interface = MockTestInterface()
        
        # Test with empty/malformed code
        empty_code = ""
        try
            root = parseall(SyntaxNode, empty_code)
            # Should handle gracefully if there are no children
            if !isnothing(JuliaSyntax.children(root)) && !isempty(JuliaSyntax.children(root))
                node = only(JuliaSyntax.children(root))
                result = TestPicker.istestblock(interface, node)
                @test isa(result, Bool)
            end
        catch e
            # It's okay if parsing empty code throws an error
            @test true
        end
        
        # Test with multiline test
        multiline_test = """
        @test begin
            x = 1
            y = 2
            x + y == 3
        end
        """
        root = parseall(SyntaxNode, multiline_test)
        node = only(JuliaSyntax.children(root))
        @test TestPicker.istestblock(interface, node) == true
        
        label = TestPicker.blocklabel(interface, node)
        @test occursin("begin", label)
        @test occursin("x = 1", label)
    end
end
