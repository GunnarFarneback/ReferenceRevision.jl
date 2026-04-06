# Tutorial for ReferenceRevision

Welcome to the tutorial for ReferenceRevision. This will walk you
through an example of investigating whether there are differences in
results between two revisions of the ConvolutionInterpolations
package.

For future reference this tutorial has been made with Julia 1.12.5.

## Add ReferenceRevision to your Global Environment

Being a development tool, ReferenceRevision is reasonable to have in
your global environment. Start `julia` (without `--project`) and do

```julia
using Pkg
Pkg.add("ReferenceRevision")
```

## Set up the Example Environment

To follow this example in detail you should make a git clone of the
ConvolutionInterpolations package from
`https://github.com/NikoBiele/ConvolutionInterpolations.jl.git` and
check out the tag `v0.15.0`. But it's probably more interesting to try
with a package you are familiar with.

## Start the Main Process

Start Julia with your copy of the ConvolutionsInterpolations package
as active project, either by running Julia with `--project` or by
using `Pkg.activate`.

Now we can load the package and use the package's first README example
as a test case.

```julia
using ConvolutionInterpolations
x = range(0, 2π, length=4)
y = sin.(x)
itp = convolution_interpolation(x, y)
x_fine = range(0, 2π, length=200)
y_fine = itp.(x_fine)
```

The question we want to investigate is whether the `y_fine` result is
the same with some earlier revisions of ConvolutionInterpolations.

## Open a Reference Process

In the same Julia session, load ReferenceRevision, open a subprocess
running ConvolutionInterpolations version 0.10.0, and compute `y_fine`
with this version.

```julia
using ReferenceRevision
ref10 = open_process(rev = "v0.10.0")
itp10 = ref10.convolution_interpolation(x, y)
y10 = itp10.(x_fine)
```

Now we can easily compare the outputs

```julia
julia> y_fine == y10
true
```

Fine, both revisions produce the same result.

## Open Another Reference Process

Let's see how version 0.9.0 compares.

```julia
ref9 = open_process(rev = "v0.9.0")
itp9 = ref9.convolution_interpolation(x, y)
y9 = itp9.(x_fine)
```

This version produces a different result.

```julia
julia> y9 == y_fine
false

julia> extrema(y9 .- y_fine)
(-0.11478758940878142, 0.11478758940878131)
```

## Closing the Processes

To close the subprocesses and recover file descriptors, run

```julia
close(rev9)
close(rev10)
```

## A Closer Look

When creating `ref10` you could probably see an output similar to

```julia
julia> ref10 = open_process(rev = "v0.10.0")
[ Info: Checking out revision v0.10.0 to /tmp/jl_VPZKI3.
v0.10.0: Precompiling packages...
v0.10.0:    4258.6 ms  ✓ ConvolutionInterpolations
v0.10.0:   1 dependency successfully precompiled in 4 seconds. 5 already precompiled.
v0.10.0 module: Main
```

The `Info:` line informs us that ReferenceRevision automatically
extracted a copy of the `v0.10.0` revision to a temporary directory.
Then it started a subprocess running the same version of Julia as the
main process, activating the environment in the temporary directory,
and loading the package with `using ConvolutionInterpolations`.

The next three lines have `v0.10.0:` written in red. This signals that
it is `stderr` output from the subprocess that has been relayed into
the main process. If there would be `stdout` output in the subprocess,
it would also be relayed and prefixed with `v0.10.0:` in green text.
If desired both of these can be redirected with keyword arguments to
`open_process`.

The final line is how the `ref10` object prints itself. Effectively it
acts as the `Main` module of the Julia running in the subprocess.

After this we created the `itp10` object.

```julia
julia> itp10 = ref10.convolution_interpolation(x, y)
v0.10.0 object: unknown
```

This involved serializing the `x` and `y` values, sending them to the
subprocess and deserializing them there, and then running the
`convolution_interpolation` function in the subprocess with the
deserialized `x` and `y` as arguments. The result is then serialized
in the subprocess, sent back to the main process, and deserialized
there.

However, in this case the result was a `struct` with different
definitions in version 0.15.0 (being run in the main process) and
version 0.10.0. This causes the deserizalization to fail, so we cannot
investigate the object, but whenever it is sent back to the
subprocess, deserialization is successful on that side.

Thus we can use it for computations inside the subprocess, as we did
next.

```julia
julia> y10 = itp10.(x_fine)
200-element Vector{Float64}:
[...]
```

This uses the broadcasting machinery in the main process to repeatedly
call the `itp10` struct (it's a callable struct) in the subprocess
with each value from `x_fine` and collecting the results into `y10` in
the main process. There's a lot of serialization and deserialization
going on, but it's invisible to the user. However, don't expect great
performance from this, since there's a substantial communication
overhead.

## Use Cases

### Debugging

The main reason for developing this package was to use it as a
debugging tool when results start to diverge between revisions. Some
notes:

* Instead of creating a temporary copy of the revision, `open_process`
  can be instructed to use a permanent location. This can e.g. be
  edited with debug prints and even be automatically reloaded by using
  `Revise` in the subprocess.

* If you have made local changes to a package, you can compare your
  results with the last commit by using `rev = "HEAD"`.

### Regression Testing

ReferenceRevision provides a convenient way to implement regression
tests by directly comparing the results of the tested code with the
results of a reference revision.

### Calling a Package With Incompatible Dependencies

Julia can only load one version of a given package in a process. As a
result it may be impossible to load two packages with mutually
incompatible dependency versions. With ReferenceRevision this problem
can be sidestepped by loading one of the packages into a subprocess.

## Trouble-shooting

* Should you get an error from the subprocess, saying that the
  environment needs to be instantiated, you can do so by adding the
  keyword argument `instantiate = true` to `open_process`. This only
  needs to be done once (for a given revision).
