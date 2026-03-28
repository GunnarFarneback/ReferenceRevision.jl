module ReferenceRevision
using Tar
include("serialization.jl")

export open_process

struct Process
    stdin::Pipe
    stdout::Pipe
    stderr::Pipe
    fd3::Pipe
    process::Base.Process
    name::String
end

struct Object
    process::Process
    data::Vector{UInt8}
    description::String
end

function Base.show(io::IO, object::Object)
    process = get_process(object)
    print(io, process. name, " ", get_description(object))
end

# Define field accessors for convenience, since getproperty is
# overloaded.
get_process(object::Object) = getfield(object, :process)
get_data(object::Object) = getfield(object, :data)
get_description(object::Object) = getfield(object, :description)

function send(object::Object, x)
    serialize(get_process(object).stdin, x)
end

function send_raw(object::Object, x)
    io = get_process(object).stdin
    write(io, length(x))
    write(io, x)
end

function receive_reply(object::Object)
    success, result, raw = deserialize(get_process(object).fd3)
    process = get_process(object)
    success || return Object(process, raw, "object: unknown")
    if result isa Module
        return Object(process, raw, "module: $(result)")
    elseif result isa Function
        return Object(process, raw, "function: $(result)")
    else
        return result
    end
end

# Dot indexing.
function Base.getproperty(object::Object, name::Symbol)
    send(object, :getproperty)
    send(object, name)
    send_raw(object, get_data(object))
    return receive_reply(object)
end

# Function call.
function (object::Object)(args...; kwargs...)
    send(object, :call)
    send(object, (args, kwargs))
    send_raw(object, get_data(object))
    return receive_reply(object)
end

function relay_stdio(io, pipe::Pipe, name, color, print_lock)
    while !eof(pipe)
        x = readavailable(pipe)
        last(x) == UInt8('\n') && pop!(x)
        s = String(x)
        lock(print_lock)
        for line in eachsplit(s, "\n")
            printstyled(io, name, ": "; color)
            println(io, line)
        end
        unlock(print_lock)
    end
end

# Compat method.
function _pipeline(cmd, redir)
    @static if VERSION >= v"1.13"
        pipeline(cmd, redir)
    else
        # This is the exact implementation in Julia 1.13.
        Base.CmdRedirect(cmd, redir.second, Int(redir.first))
    end
end

function open_process(env = nothing; name = nothing, rev = nothing,
                     use = nothing, git = nothing)
    env, name = resolve_environment(env, rev, name, git)
    stdin′ = Pipe()
    stdout′ = Pipe()
    stderr′ = Pipe()
    fd3 = Pipe()
    Base.link_pipe!(fd3, reader_supports_async=true)
    process_script = joinpath(@__DIR__, "process.jl")
    p = run(_pipeline(pipeline(`$(Base.julia_cmd()) $(process_script) $env`,
                               stdin = stdin′, stdout = stdout′,
                               stderr = stderr′), 3 => fd3),
            wait = false)
    print_lock = ReentrantLock()
    Threads.@spawn relay_stdio(stdout, stdout′, name, :green, print_lock)
    Threads.@spawn relay_stdio(stderr, stderr′, name, :red, print_lock)
    object = Object(Process(stdin′, stdout′, stderr′, fd3, p, name),
                          _serialize(Main), "module: Main")
    if !isnothing(use)
        if !(use isa AbstractVector)
            use = [use]
        end
        expr = Meta.parse("using " * join(use, ", "))
        object.eval(expr)
    end
    return object
end

function resolve_environment(env, rev, name, git)
    if isnothing(rev)
        if isnothing(env)
            env = pwd()
        end
        if isnothing(name)
            name = "Process"
        end
    else
        init = false
        if isnothing(env)
            env = mktempdir()
            init = true
        elseif !ispath(env)
            mkpath(env)
            init = true
        else
            @info "$(env) already exists, reusing what's there."
        end
        if isnothing(name)
            name = rev
        end
        if init
            @info "Checking out revision $(rev) to $(env)."
            Tar.extract(`git archive $(rev)`, env)
        end
    end
    return env, name
end

function Base.close(object::Object)
    send(object, :quit)
    process = get_process(object)
    close(process.stdin)
    close(process.stdout)
    close(process.stderr)
    close(process.fd3)
    wait(process.process)
end

end
