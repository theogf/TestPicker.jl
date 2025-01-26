using TestPicker
using Documenter

DocMeta.setdocmeta!(TestPicker, :DocTestSetup, :(using TestPicker); recursive=true)

makedocs(;
    modules=[TestPicker],
    authors="theogf <theo.galyfajou@gmail.com> and contributors",
    sitename="TestPicker.jl",
    format=Documenter.HTML(;
        canonical="https://theogf.github.io/TestPicker.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/theogf/TestPicker.jl",
    devbranch="main",
)
