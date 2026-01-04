@setup_workload begin
    # Precompile common operations based on existing tests
    pkg_spec = PackageSpec(; name="TestPicker", path=pkgdir(@__MODULE__))
    # Putting some things in `@compile_workload` will add to the precompile statements
    @compile_workload begin

        # Test file operations
        try
            root, testfiles = get_testfiles(pkg_spec)

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
            if !isempty(testfiles)
                testfile = joinpath(root, first(testfiles))
                if isfile(testfile)
                    get_testblocks([interface], testfile)
                end
            end

            # File matching operations
            get_matching_files("test", testfiles)

            # Build info to syntax
            if !isempty(testfiles)
                matched_files = [first(testfiles)]
                build_info_to_syntax([interface], root, matched_files)
            end

            # Precompile Cmd and pipeline construction (without executing)
            # This covers the fzf command construction overhead
            tmpfile = tempname()
            fzf_args = ["-m", "--query", "test", "--filter", "test"]
            fzf_cmd = `$(fzf()) $(fzf_args)`

            # Just construct the Cmd object, don't run it
            Cmd(fzf_cmd; ignorestatus=true, dir=root)

            # Construct pipeline object without executing
            test_pipeline = pipeline(
                Cmd(fzf_cmd; ignorestatus=true, dir=root); stdin=IOBuffer("test\n")
            )

            # Precompile bat path construction
            bat_path = get_bat_path()
            `$(bat_path) --color=always --style=numbers test.jl`

            # Cleanup temp file if created
            isfile(tmpfile) && rm(tmpfile)
        catch
            # Ignore errors during precompilation workload
        end
    end
end
