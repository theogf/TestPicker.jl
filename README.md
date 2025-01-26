# TestPicker

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://theogf.github.io/TestPicker.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://theogf.github.io/TestPicker.jl/dev/)
[![Build Status](https://github.com/theogf/TestPicker.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/theogf/TestPicker.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/theogf/TestPicker.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/theogf/TestPicker.jl)
[![Code Style: Blue](https://img.shields.io/badge/code%20style-blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)

Simple test picker tool to run a unique test file from the REPL instead of the whole testsuite.

To activate `test` mode press `!`.

Then you will get the following prompt

```julia-repl
test> 
```

Input some fuzzy input to find the desired test file, e.g.:

```julia-repl
test> subdir/c
```

which will get you a fuzzy search, press enter and the file will be run under the test environment.

```julia
[ Info: Executing test file /home/theo/.julia/dev/TestPicker/test/test-subdir/test-file-c.jl
```

Make sure that your environment is set to use the package you are testing.
