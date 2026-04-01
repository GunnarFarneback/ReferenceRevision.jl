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

function discard_values(n)
    for _ in 1:n
        deserialize(stdin)
    end
end

# Code compactifying macro. `@deserialize x` expands to
#     success, x, _ = invokelatest(deserialize, stdin)
#     num_remaining_values -= 1
#     if !success
#         discard_values(num_remaining_values)
#         return internal_error("failed to deserialize x.")
#     end
macro deserialize(x)
    quote
        success, $(esc(x)), _ = invokelatest(deserialize, stdin)
        $(esc(:num_remaining_values)) -= 1
        if !success
            discard_values($(esc(:num_remaining_values)))
            return internal_error(string("failed to deserialize ",
                                         $(esc(x)), "."))
        end
    end
end

function process_message(method, num_remaining_values)
    result = nothing
    @deserialize object
    if method == :getproperty
        @deserialize field
        try
            result = invokelatest(getproperty, object, field)
        catch e
            showerror(stderr, e)
        end
    elseif method == :setproperty!
        @deserialize field
        @deserialize value
        try
            result = invokelatest(setproperty!, object, field, value)
        catch e
            showerror(stderr, e)
        end
    elseif method == :getindex
        @deserialize num_indices
        indices = []
        for _ in 1:num_indices
            @deserialize index
            push!(indices, index)
        end
        try
            result = invokelatest(getindex, object, indices...)
        catch e
            showerror(stderr, e)
        end
    elseif method == :setindex!
        @deserialize value
        @deserialize num_indices
        indices = []
        for _ in 1:num_indices
            @deserialize index
            push!(indices, index)
        end
        try
            result = invokelatest(setindex!, object, value, index...)
        catch e
            showerror(stderr, e)
        end
    elseif method == :call
        @deserialize num_args
        args = []
        for _ in 1:num_args
            @deserialize arg
            push!(args, arg)
        end
        @deserialize kw_names
        kw_values = []
        for _ in 1:length(kw_names)
            @deserialize kw_value
            push!(kw_values, kw_value)
        end
        kwargs = (; zip(kw_names, kw_values)...)
        try
            result = invokelatest(object, args...; kwargs...)
        catch e
            showerror(stderr, e)
        end
    else
        discard_values(num_remaining_values)
        return internal_error("unknown message type $(method).")
    end
    if num_remaining_values > 0
        discard_values(num_remaining_values)
        return internal_error(num_remaining_values *
                              " unused values for message type $(method).")
    elseif num_remaining_values < 0
        internal_error(" needed " * num_remaining_values *
                       "more value for message type $(method)",
                       fatal = true)
    end
    return result
end

function process(args)
    Pkg.activate(args[1], io = devnull)
    Pkg.instantiate(io = devnull)
    output = open(RawFD(3))
    data = UInt8[]
    while !eof(stdin)
        _, num_values, _ = deserialize(stdin)
        _, method, _ = deserialize(stdin)
        method == :quit && break
        result = process_message(method, num_values - 1)
        send_reply(output, result)
    end
    close(output)
end

process(ARGS)
