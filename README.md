# ReferenceRevision

ReferenceRevision is a Julia package which can automatically check out
a copy of your code at a different revision and run it in a subprocess
with seamless sharing of variables.

More generally it can run code in an arbitrary environment from within
your current session, even if that environment has different and
possibly conflicting dependencies relative to your current
environment.

## Installation

```
using Pkg
Pkg.add("https://github.com/GunnarFarneback/ReferenceRevision.jl.git")
```

## Example

Assume that you are developing your package `Mogrify` and find that
you want to compare results to what you had in your latest commit. You
could stash your changes, and possibly, with the help of `Revise`,
keep running in the same session and be able to directly look at the
differences in results. However, this is quite fiddly, especially if
you have to go back and forth repeatedly in a debugging session.

With this package you can instead do
```
using ReferenceRevision
head = open_process(rev = "HEAD", use = :Mogrify)
out = mogrify(image)
out_head = head.mogrify(image)
```

The `open_process` call extracts the files from the `HEAD` revision to
a temporary directory, starts a new Julia process in that enviroment
and runs `using Mogrify`. The `head.mogrify(image)` call transfers
`image` to the `head` process, runs the `mogrify` function in that
process, and transfers the result back to the main session.

This is not limited to the exported function `mogrify` but can access
any function in the `Mogrify` package,
e.g. `head.Mogrify.SubModule.some_function`.

You can also start more processes if you need to compare with other
revisions, e.g.
```
tag = open_process(rev = "v2.3", use = :Mogrify)
```
