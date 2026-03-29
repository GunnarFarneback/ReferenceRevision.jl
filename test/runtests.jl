using ReferenceRevision
using Test
using Pkg

include("test_environment.jl")

@testset "Own environment" begin
    # Tests run with the test directory as current directory but we
    # want the reference process to run in the package environment.
    cd("..") do
        ref = open_process(stderr = devnull)
        @test VERSION == ref.VERSION
        @test sin(1) == ref.sin(1)
        @test isnothing(ref.uuid4)
        ref.eval(:(using UUIDs))
        @test ref.uuid4 isa ReferenceRevision.Object
        @test ref.uuid4() isa Base.UUID
        close(ref)

        ref = open_process(use = :UUIDs)
        @test ref.uuid4() isa Base.UUID
        close(ref)
    end
end

@testset "Relay and redirection" begin
    cd("..") do
        buf_out1 = IOBuffer()
        buf_err1 = IOBuffer()
        buf_out2 = IOBuffer()
        buf_err2 = IOBuffer()
        # Relay of Base.stdout and Base.stderr. Sadly there is no easy
        # way to redirect to an IOBuffer.
        mktemp() do out_path, out_io
            mktemp() do err_path, err_io
                redirect_stdout(out_io) do
                    redirect_stderr(err_io) do
                        ref = open_process()
                        ref.println("A")
                        ref.error("B")
                        close(ref)
                        ref = open_process(name = "ref1",
                                           stdout = buf_out1)
                        ref.println("C")
                        ref.error("D")
                        close(ref)
                        ref = open_process(name = "ref2",
                                           stderr = buf_err1)
                        ref.println("E")
                        ref.error("F")
                        close(ref)
                        ref = open_process(name = "ref3",
                                           stdout = buf_out2,
                                           stderr = buf_err2)
                        ref.println("G")
                        ref.error("H")
                        close(ref)
                    end
                end
                close(out_io)
                close(err_io)
                @test read(out_path, String) == "Process: A\nref2: E\n"
                @test read(err_path, String) == "Process: B\nref1: D\n"
                @test String(take!(buf_out1)) == "C\n"
                @test String(take!(buf_err1)) == "F"
                @test String(take!(buf_out2)) == "G\n"
                @test String(take!(buf_err2)) == "H"
            end
        end
    end
end

@testset "TestPackage environment" begin
    mktempdir() do dir
        redirect_stdout(devnull) do
            create_test_environment(dir)
        end
        Pkg.activate(dir, io = devnull)
        # Standard usage, automatic using of the package in the
        # environment.
        @eval import TestPackage
        ref = open_process(rev = "commit1", quiet = true)
        x = 1:10
        f = invokelatest(getfield, invokelatest(getfield, Main, :TestPackage), :f)
        @test invokelatest(f, x) == 3:12
        @test ref.f(x) == 2:11
        close(ref)
        ref = open_process(rev = "commit2", quiet = true)
        @test ref.f(x) == 3:12
        close(ref)
        # Inhibit using of the package in the environment.
        ref = open_process(rev = "commit2", quiet = true, use = false,
                           stderr = devnull)
        @test isnothing(ref.TestPackage)
        close(ref)

        # Test subdir, which is a non-package environment.
        ref = open_process(rev = "commit3", subdir = "benchmark",
                           quiet = true, stderr = devnull)
        @test isnothing(ref.BenchmarkTools)
        ref.eval(:(import BenchmarkTools))
        @test ref.BenchmarkTools isa ReferenceRevision.Object
        close(ref)
        # Specify the use argument in a few different ways.
        for use in [:BenchmarkTools,
                    "BenchmarkTools",
                    [:BenchmarkTools],
                    ["BenchmarkTools"],
                    Union{Symbol, String}[:BenchmarkTools,
                                          "BenchmarkTools"]]
            ref = open_process(;rev = "commit3", subdir = "benchmark",
                               quiet = true, use)
            @test ref.BenchmarkTools isa ReferenceRevision.Object
            close(ref)
        end

        # Extract revision to a non-temporary directory.
        mktempdir() do tmpdir
            # Need a non-existent, not just empty, directory.
            tmpdir = joinpath(tmpdir, "ref")
            ref = open_process(path = tmpdir, rev = "commit1",
                               quiet = true, stderr = devnull)
            @test ref.f(x) == 2:11
            close(ref)
            ref = open_process(path = tmpdir, rev = "commit2",
                               quiet = true, stderr = devnull)
            # Existing directory was reused, rev ignored.
            @test ref.f(x) == 2:11
            close(ref)
        end

        # Test automatic subdir when current environment is in a
        # subdirectory of the git clone.
        Pkg.activate(joinpath(dir, "benchmark"), io = devnull)
        ref = open_process(rev = "HEAD", quiet = true,
                           stderr = devnull, use = :BenchmarkTools)
        @test ref.BenchmarkTools isa ReferenceRevision.Object
        close(ref)
    end
end
