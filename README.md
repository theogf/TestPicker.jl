# TestPicker

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://theogf.dev/TestPicker.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://theogf.dev/TestPicker.jl/dev/)
[![Build Status](https://github.com/theogf/TestPicker.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/theogf/TestPicker.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/theogf/TestPicker.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/theogf/TestPicker.jl)
[![Code Style: Blue](https://img.shields.io/badge/code%20style-blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)

Simple fuzzy test picker to run a unique test file or test block from the REPL instead of the whole testsuite.

## Install

Once this package is registered, you can do 

```
] add TestPicker
```

Since it is a global tool, I would recommend installing in your global environment.

## Usage

### Activating the REPL mode

Simply running

```julia
using TestPicker
```

will load the new REPL mode into your session. You can add this line to your `startup.jl` file.

To activate the mode press `!` in a new line and you will get the following prompt:

```julia-repl
test> 
```

### Running test files

Input some fuzzy input to find the desired test file(s), e.g.:

```julia-repl
test> subdirfile
```

which will get you a fuzzy search, press enter and the file will be run under the test environment.

```julia
[ Info: Executing test file /home/theo/.julia/dev/TestPicker/test/test-subdir/test-file-c.jl
```

Once executed, your original environment will be restored.

#### Running multiple files

You can select multiple files to run in the `fzf` selection with `Tab` and `Shift+Tab`.

### Running test blocks

If the character `:` appears in your query, `TestPicker` will instead look for toplevel `@testset` present in your `test` folder. Any preamble like `using Test`, `config = ...` will be run as well as long as it is outside of the `@testset` block.

The syntax is the following

```julia-repl
test> fuzzy-file-name:fuzzy-test-set-name
```

which will give you e.g. the following selection

```
"I am another testset  |    test-b.jl:6
"I am a testset"       |    test-a.jl:3
```

### Repeating latest test

After running a collection of test files and/or testsets you can just repeat the same operation by calling `-`(in the samme fashion as `cd -`):

```
test> test-a
[ Info: Executing test file /home/theo/.julia/dev/TestPicker/test/sandbox/test-a.jl
Test Summary:                                                        | Pass  Total  Time
TestPicker - /home/theo/.julia/dev/TestPicker/test/sandbox/test-a.jl |    1      1  0.0s

test> -
[ Info: Executing test file /home/theo/.julia/dev/TestPicker/test/sandbox/test-a.jl
Test Summary:                                                        | Pass  Total  Time
TestPicker - /home/theo/.julia/dev/TestPicker/test/sandbox/test-a.jl |    1      1  0.0s
```

### Execution

- All selections will be run inside a module, in a similar fashion to [`SafeTestsets.jl`](https://github.com/YingboMa/SafeTestsets.jl).
- Before running any selection, [`TestEnv.jl`](https://github.com/JuliaTesting/TestEnv.jl) `activate()` is used to mimick the `Pkg.test()` behaviour.

The syntax is the following

```julia-repl
test> fuzzy-file-name:fuzzy-test-set-name
```

which will give you e.g. the following selection

```
"I am another testset  |    test-b.jl:6
"I am a testset"       |    test-a.jl:3
```

### Execution
s- 
All selection will be run inside a module, in a similar fashion to [`SafeTestsets.jl`]().
-Before running any selection, [`TestEnv.jl`]() `activate()` is us to mimick the `Pkg.test()` behaviour. The original environment is restored afterwards, regardless of the outcome.

## Known issues

Syntax highlighting is achieved by running `bat` within `fzf`, however
[the signals needed to detect light/dark terminal background osc10/osc11 don't work in this case](https://github.com/junegunn/fzf/issues/4317).
This means some characters may have too low contrast against the background to be readable.

The current workaround is to set a theme manually using the `BAT_THEME` environment
variable e.g. add `export BAT_THEME=GitHub` to your `~/.bashrc` 

## Misc

- [A great blog post](https://erik-engheim.medium.com/exploring-julia-repl-internals-6b19667a7a62) on Julia REPL mechanics
- [TestItemRunner.jl](https://github.com/julia-vscode/TestItemRunner.jl) a package that work in vscode to run its own `@testitem` tests.
- [ReTest.jl](https://github.com/JuliaTesting/ReTest.jl) a testing framework that also let you filter testsets.
