
function find_related_testfile(str::AbstractString)
    root, files = get_test_files()
    # Run fzf to get a relevant file.
    file = fzf() do exe
        chomp(
            read(
                pipeline(
                    Cmd(`$(exe) --query $str`; ignorestatus=true);
                    stdin=IOBuffer(join(files, '\n')),
                ),
                String,
            ),
        )
    end
    if isempty(file)
        @debug "Could not find any file with query $str"
        file
    else
        joinpath(root, file)
    end
end

function get_test_files()
    dir = current_pkg_dir()
    test_dir = joinpath(dir, "test")
    isdir(test_dir) || error(
        "the test directory $(test_dir) does not exist, you need to activate your package environment first",
    )
    # Recursively get a list of julia files.
    return test_dir,
    mapreduce(vcat, walkdir(test_dir)) do (root, _, files)
        relpath.(filter(endswith(".jl"), joinpath.(Ref(root), files)), Ref(test_dir))
    end
end
