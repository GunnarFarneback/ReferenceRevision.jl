using Pkg

include("serialization.jl")

function read_message()
    return deserialize(stdin)
end

function send_reply(io, x)
    serialize(io, x)
end

function internal_error(message; fatal = false)
    println(stderr, fatal ? "Fatal i" : "I", "nternal error: ", message)
    fatal && exit(1)
    return nothing
end

function process_message(method)
    result = nothing
    if method == :getproperty
        success, field, _ = deserialize(stdin)
        success || return internal_error("failed to deserialize field name.")
        success, object, _ = deserialize(stdin)
        success || return internal_error("failed to deserialize object.")
        try
            result = invokelatest(getproperty, object, field)
        catch e
            showerror(stderr, e)
        end
    elseif method == :call
        success, x, _ = deserialize(stdin)
        success || return internal_error("failed to deserialize arguments.")
        args, kwargs = x
        success, object, _ = deserialize(stdin)
        success || return internal_error("failed to deserialize object.")
        result = nothing
        try
            result = invokelatest(object, args...; kwargs...)
        catch e
            showerror(stderr, e)
        end
    else
        internal_error("unknown message type $(method).", fatal = true)
    end
    return result
end

function process(args)
    Pkg.activate(args[1], io = devnull)
    Pkg.instantiate(io = devnull)
    output = open(RawFD(3))
    data = UInt8[]
    while !eof(stdin)
        _, method, _ = deserialize(stdin)
        method == :quit && break
        result = process_message(method)
        send_reply(output, result)
    end
    close(output)
end

process(ARGS)
