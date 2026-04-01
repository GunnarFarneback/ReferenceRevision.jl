using UUIDs: uuid4

# In the directory `dir`, generate a small package with an additional
# environment in a subdirectory. Make a couple of commits to play
# with.
function create_test_environment(dir)
    write_file(dir, "Project.toml",
               """
               name = "TestPackage"
               uuid = "$(uuid4())"
               version = "0.0.1"
               """)
    src = joinpath(dir, "src")
    mkpath(src)
    write_file(src, "TestPackage.jl",
               """
               module TestPackage
               export f
               f(x) = x .+ 1
               mutable struct M
                   x::Int
               end
               const s = M(1)
               const r = Ref(M(2))
               g(a::M, b::Int; c::M, d::Int) = M((a.x + d) * (b + c.x))
               end
               """)
    run(`git -C $dir init`)
    run(`git -C $dir config user.email "ci@ci"`)
    run(`git -C $dir config user.name ci`)
    run(`git -C $dir add .`)
    run(`git -C $dir commit -m "."`)
    run(`git -C $dir tag commit1`)

    write_file(src, "TestPackage.jl",
               """
               module TestPackage
               export f
               f(x) = x .+ 2
               end
               """)
    run(`git -C $dir commit -a -m "."`)
    run(`git -C $dir tag commit2`)

    benchmark = joinpath(dir, "benchmark")
    mkpath(benchmark)
    write_file(benchmark, "Project.toml",
               """
               [deps]
               BenchmarkTools = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"
               """)
    run(`git -C $dir add benchmark`)
    run(`git -C $dir commit -m "."`)
    run(`git -C $dir tag commit3`)
end

write_file(dir, filename, contents) = write(joinpath(dir, filename), contents)
