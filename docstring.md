# Reference Documentation for ReferenceRevision
## Docstring for `open_process`

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

### Keyword arguments related to the environment

These keywords determine what environment the subprocess should activate.

* `path`: Path to the environment or to the extracted git revision.
* `rev`: Git revision to extract.
* `subdir`: Subdirectory to use for the environment.
* `instantiate`: If `true`, run `Pkg.instantiate` after activating the
  environment. Defaults to `false`.

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

### Keyword argument related to package imports

* `use`: Package(s) to import with `using`.

These can be specified as symbols or strings, or a vector of either.
If omitted or `true`, and if the activated environment is a package,
only that package will be imported. If `false`, no import will be
made.

If you want to import packages with `import` instead of `using`, this
can be done manually with

    process = open_process(; ...)
    process.eval(:(import Example))

### Keyword arguments related to stdio of subprocess

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

### Other keyword arguments

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
