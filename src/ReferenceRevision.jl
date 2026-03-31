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
function send(object::Object, x)
    serialize(get_process(object).stdin, x)
end

# Send an already serialized object to the remote side. The
# serialization was originally made on the remote side.
function send_raw(object::Object, x)
    io = get_process(object).stdin
    write(io, length(x))
    write(io, x)
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

# Dot indexing of remote object.
function Base.getproperty(object::Object, name::Symbol)
    send(object, :getproperty)
    send(object, name)
    send_raw(object, get_data(object))
    return receive_reply(object)
end

# Remote function call.
function (object::Object)(args...; kwargs...)
    send(object, :call)
    send(object, (args, kwargs))
    send_raw(object, get_data(object))
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

"""
    process = open_process(; kwargs...)

Spawn and connect to a subprocess running the same version of Julia as
the current session but activating an independent environment. All
arguments are keyword arguments with default values. Omitting all of
them will activate the environment in the current directory, and if
that is a package environment, import that package with `using`.

The return value is an object which acts as the `Main` module of the
spawned process. Function arguments and return values are transferred
between the current session and the spawned process.

*Example:*

    using ReferenceRevision
    process = open_process()
    e = process.exp(1)

A subprocess can be exited and file descriptors reclaimed by calling
`close`.

**Keyword arguments related to the environment:**

* `path`: Path to the environment or to the extracted git revision.
* `rev`: Git revision to extract.
* `subdir`: Subdirectory to use for the environment.

If `rev` is not provided, ignore `subdir` and activate the environment
in `path`. If `path` is also omitted, activate the current directory
(which may be different from the environment of the current session).

If `rev` is provided, the current environment must be within a git
clone. `rev` may be any reference known to git, such as `HEAD`, a
branch name, a tag name, or a commit hash. If `path` is omitted, the
`rev` revision will be extracted into a temporary directory, which
will be automatically removed once the process is closed or the
current session is exited. If `path` is given but does not exist,
`rev` will be extracted into `path`, and not removed on close or exit.
If path is given and exists, it is assumed that `rev` has already been
extracted there. If `subdir` is provided, activate the environment in
that subdirectory of the extracted revision. If `subdir` is not
provided, activate the same subdirectory as the current environment is
located relative to the git root directory.

**Keyword argument related to package imports:**

* `use`: Package(s) to import with `using`.

These can be specified as symbols or strings, or a vector of either.
If omitted or `true`, and if the activated environment is a package,
only that package will be imported. If `false`, no import will be
made.

If you want to import packages with `import` instead of `using`, this
can be done manually with

    process = open_process(; ...)
    process.eval(:(import Example))

**Keyword arguments related to stdio of subprocess:**

By default subprocess output on `stdout` and `stderr` is relayed to the
corresponding streams in the current session, prefixed by an
identifier which is colored green for `stdout` and `red` for stderr.

* `name`: Name to use as prefix. If omitted it defaults to `rev`, or
  if that is omitted, to `"process"`. `name` is also used in the
  `show` function for subprocess objects in the main process.

* `stdout`: If provided, do not relay `stdout` but instead send it to
  a filename or an IO stream. The `devnull` stream can be used to
  discard the output.

* `stderr`: If provided, do not relay `stderr` but instead send it to
  a filename or an IO stream. The `devnull` stream can be used to
  discard the output.

**Other keyword arguments:**

* `quiet`: If `false` or omitted, write diagnostics about extraction
  of git revisions and activated environments. If `true`, suppress
  that information.

* `git`: If omitted, use the system `git` command. Otherwise this can
  be specified as a string or a `Cmd`. See examples below.

Example 1, use an external git not on `PATH`:

    process = open_process(..., git = "/opt/bin/git")

Example 2, use a git provided by a Julia package:

    import Git
    process = open_process(..., git = Git.git())

"""
function open_process(; path::Union{AbstractString, Nothing} = nothing,
                      rev::Union{AbstractString, Nothing} = nothing,
                      subdir::Union{AbstractString, Nothing} = nothing,
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
    p = run(_pipeline(pipeline(`$(Base.julia_cmd()) $(process_script) $env`,
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
    object = Object(process, _serialize(Main), "module: Main")
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
