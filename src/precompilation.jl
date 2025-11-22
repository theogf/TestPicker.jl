@setup_workload begin
    # Precompile common operations based on existing tests
    pkg_spec = PackageSpec(; name="TestPicker", path=pkgdir(@__MODULE__))
    # Putting some things in `@compile_workload` will add to the precompile statements
    @compile_workload begin

        # Test file operations
        try
            root, test_files = get_test_files(pkg_spec)

            # Test block operations
            interface = StdTestset()
            test_code = """
            @testset "test" begin
                @test true
            end
            """
            node = parseall(SyntaxNode, test_code)
            if !isnothing(JuliaSyntax.children(node)) &&
                !isempty(JuliaSyntax.children(node))
                test_node = only(JuliaSyntax.children(node))
                istestblock(interface, test_node)
                blocklabel(interface, test_node)
            end

            # Get testblocks from a test file
            if !isempty(test_files)
                test_file = joinpath(root, first(test_files))
                if isfile(test_file)
                    get_testblocks([interface], test_file)
                end
            end

            # File matching operations
            get_matching_files("test", test_files)

            # Build info to syntax
            if !isempty(test_files)
                matched_files = [first(test_files)]
                build_info_to_syntax([interface], root, matched_files)
            end
        catch
            # Ignore errors during precompilation workload
        end
    end
end
