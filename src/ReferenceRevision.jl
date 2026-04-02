module ReferenceRevision
using Tar
using TOML
include("serialization.jl")

# Only this one exported function is public. Everything else are
# internals.
export open_process

struct Process
    stdin::Pipe
    fd3::Pipe
    objects_to_close::Vector{Any}
    process::Base.Process
    name::String
    temp_dir::String
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

# Serialize a local object and send it to the remote side.
function send(io::IO, x)
    serialize(io, x)
end

# Send an already serialized object to the remote side. The
# serialization was originally made on the remote side.
function send(io::IO, x::Object)
    wrapped_serialize(io, get_data(x))
end

function send(object::Object, values...)
    io = get_process(object).stdin
    send(io, length(values))
    for value in values
        send(io, value)
    end
end

# Receive the result of a remote operation.
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

# Dot indexing of remote object. It's questionable whether
# `setproperty!` can actually be used meaningfully due to
# serialization/deserialization creating new objects.
function Base.getproperty(object::Object, name::Symbol)
    send(object, :getproperty, object, name)
    return receive_reply(object)
end

function Base.setproperty!(object::Object, name::Symbol, value)
    send(object, :setproperty!, object, name, value)
    return receive_reply(object)
end

# Bracket indexing of remote object. It's questionable whether
# `setindex!` can actually be used meaningfully due to
# serialization/deserialization creating new objects.
function Base.getindex(object::Object, index...)
    send(object, :getindex, object, length(index), index...)
    return receive_reply(object)
end

function Base.setindex!(object::Object, value, index...)
    send(object, :setindex!, object, value, length(index), index...)
    return receive_reply(object)
end

# Remote function call.
function (object::Object)(args...; kwargs...)
    # It would be easier to just send (args, kwargs) in one argument,
    # but that wouldn't support sending back opaque values received
    # from the subprocess.
    send(object, :call, object, length(args), args...,
         keys(kwargs), values(kwargs)...)
    return receive_reply(object)
end

# stdout and stderr on the remote side is relayed back to the main
# session, prefixed with a color coded identifier. Output is only
# flushed once a newline is received, and after end of file.
function relay_stdio(io, pipe::Pipe, name, color, print_lock)
    s = ""
    while !eof(pipe)
        x = readavailable(pipe)
        s *= String(x)
        lock(print_lock)
        while contains(s, "\n")
            line, s = split(s, "\n", limit = 2)
            printstyled(io, name, ": "; color)
            println(io, line)
        end
        unlock(print_lock)
    end
    if !isempty(s)
        printstyled(io, name, ": "; color)
        println(io, s)
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

# The docstring is located in a separate file and reused for web
# documentation. Read it and chop off a couple of lines which are not
# relevant in this place.
docstring = read(joinpath(@__DIR__, "..", "docstring.md"), String)
docstring = last(split(docstring, "\n\n", limit = 2))

"$docstring"
function open_process(; path::Union{AbstractString, Nothing} = nothing,
                      rev::Union{AbstractString, Nothing} = nothing,
                      subdir::Union{AbstractString, Nothing} = nothing,
                      instantiate::Bool = false,
                      use::Union{Bool, Symbol, AbstractString,
                                 Vector{<:Union{Symbol, AbstractString}},
                                 Nothing} = nothing,
                      name::Union{AbstractString, Nothing} = nothing,
                      stdout::Union{AbstractString, IO, Nothing} = nothing,
                      stderr::Union{AbstractString, IO, Nothing} = nothing,
                      quiet::Bool = false,
                      git::Union{AbstractString, Cmd, Nothing} = nothing)
    env, name, temp_dir = resolve_environment(path, rev, subdir,
                                              name, quiet, git)
    objects_to_close = Any[]
    stdin′ = Pipe()
    stdout′ = redirect_stdio(stdout, objects_to_close)
    stderr′ = redirect_stdio(stderr, objects_to_close)
    fd3 = Pipe()
    Base.link_pipe!(fd3, reader_supports_async=true)
    process_script = joinpath(@__DIR__, "process.jl")
    p = run(_pipeline(pipeline(`$(Base.julia_cmd()) $(process_script) $env $instantiate`,
                               stdin = stdin′, stdout = stdout′,
                               stderr = stderr′), 3 => fd3),
            wait = false)
    if isnothing(stdout) || isnothing(stderr)
        print_lock = ReentrantLock()
        if isnothing(stdout)
            Threads.@spawn relay_stdio(Base.stdout, stdout′, name,
                                       :green, print_lock)
        end
        if isnothing(stderr)
            Threads.@spawn relay_stdio(Base.stderr, stderr′, name,
                                       :red, print_lock)
        end
    end
    process = Process(stdin′, fd3, objects_to_close, p, name, temp_dir)
    object = Object(process, serialize(Main), "module: Main")
    if isnothing(use) || use == true
        use = find_package_environment(env)
    end
    if !isnothing(use) && use != false
        if use isa AbstractVector
            s = "using " * join(use, ", ")
        else
            s = "using $(use)"
        end
        object.eval(Meta.parse(s))
    end
    return object
end

function redirect_stdio(target, objects_to_close)
    if isnothing(target)
        io = Pipe()
        push!(objects_to_close, io)
    elseif target isa AbstractString
        io = open(target, "w")
        push!(objects_to_close, io)
    else
        io = target
    end
    return io
end

# Determine whether `env` is a package environment and return its name.
function find_package_environment(env)
    for project_file in Base.project_names
        path = joinpath(env, project_file)
        if isfile(path)
            try
                project = TOML.parsefile(path)
                haskey(project, "uuid") || return nothing
                return get(project, "name", nothing)
            catch e
                return nothing
            end
        end
    end
    return nothing
end

# Figure out where the new environment is located and retrieve it from
# git if needed. Fill in a default name if not provided.
function resolve_environment(path, rev, subdir, name, quiet, git)
    temp_dir = ""
    if isnothing(rev)
        isnothing(path) && (path = pwd())
        isnothing(name) && (name = "Process")
        env = path
    else
        init = false
        if isnothing(path)
            path = mktempdir()
            temp_dir = path
            init = true
        elseif !ispath(path)
            mkpath(path)
            init = true
        elseif !quiet
            @info "$(path) already exists, reusing what's there."
        end
        isnothing(name) && (name = rev)
        current_env = dirname(Base.active_project())
        isnothing(git) && (git = "git")
        if init
            quiet || @info "Checking out revision $(rev) to $(path)."
            root_dir = readchomp(`$(git) -C $(current_env) rev-parse --show-toplevel`)
            Tar.extract(`$(git) -C $(root_dir) archive $(rev)`, path)
        end
        if isnothing(subdir)
            subdir = readchomp(`$(git) -C $(current_env) rev-parse --show-prefix`)
        end
        env = joinpath(path, subdir)
    end
    return env, name, temp_dir
end

# Close down the remote process and communication channels. If a
# temporary directory was created when opening the process, remove it
# and its contents.
function Base.close(object::Object)
    send(object, :quit)
    process = get_process(object)
    close(process.stdin)
    close(process.fd3)
    foreach(close, process.objects_to_close)
    if !isempty(process.temp_dir)
        rm(process.temp_dir, force = true, recursive = true)
    end
    wait(process.process)
end

end
