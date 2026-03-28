using ReferenceRevision
using Test

@testset "Package environment" begin
    # Tests run with the test directory as current directory but we
    # want the reference process to run in the package environment.
    cd("..") do
        ref = open_process()
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
