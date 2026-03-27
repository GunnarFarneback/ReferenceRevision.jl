import Serialization

# Preface Serialization.serialize with a length header, so we can
# predictably remove the correct number of bytes from the stream, even
# if deserialization fails.
function serialize(io::IO, x)
    buf = IOBuffer()
    Serialization.serialize(buf, x)
    write(io, position(buf))
    write(io, take!(buf))
end

# Raw serialization returned as `Vector{UInt8}`.
function _serialize(x)
    b = IOBuffer()
    Serialization.serialize(b, x)
    return take!(b)
end

# Return:
# 1. Whether deserialization was successful.
# 2. Deserialized value. This is `nothing` if deserialization failed.
# 3. Raw data.
#
# The correct number of bytes is always read from `io`.
function deserialize(io::IO)
    n = read(io, Int)
    raw = read(io, n)
    x = nothing
    success = false
    try
        x = Serialization.deserialize(IOBuffer(raw))
        success = true
    catch e
    end
    return success, x, raw
end
