# Bazel monorepo → conda packages → pixi

A Bazel monorepo that produces three conda packages, consumed by pixi both
from **inside** the repository and from a workspace **outside** it.

```
monorepo/
├── MODULE.bazel           rules_rattler; @conda from third_party/pixi.lock
├── pixi.toml              [workspace] + [package] (backend: pixi-build-bazel)
├── third_party/pixi.toml  conda packages Bazel compiles against (zlib)
├── libgreet/              cc_shared_library  → conda package `libgreet`
├── greet-cli/             cc_binary          → conda package `greet-cli`
└── py-greet/              py_library (ctypes) → conda package `py-greet`
../monorepo-consumer/
└── pixi.toml              depends on greet-cli / py-greet from ../monorepo
```

| package | contents | run dependencies (all derived by Bazel) |
|---|---|---|
| `libgreet` | `lib/libgreet.so`, `include/libgreet/greet.h` | `libzlib >=1.3.2,<2.0a0` (zlib's run_exports, from the lock) |
| `greet-cli` | `bin/greet` | `libgreet ==0.1.0`, `libzlib …` |
| `py-greet` | `site-packages/greet/` (noarch: python) | `libgreet ==0.1.0`, `python` |

Binaries are relocatable: Bazel's `_solib_*` rpaths are rewritten to
`$ORIGIN/../lib` (`bin/greet`) and `$ORIGIN/` (`lib/libgreet.so`) when the
packages are created.

## Run

The quickest way is the script. It checks the prerequisites, fetches a pinned
bazelisk if you don't have one, builds the backend, and runs everything below:

```sh
./try.sh            # plain Bazel, then pixi inside and outside the repo
./try.sh --fresh    # start from scratch (removes the pixi environments)
./try.sh --bazel    # only the plain Bazel part
```

Or step by step:

```sh
# once: the backend and a Bazel binary (the official one; bazelisk is fine)
(cd ../../backends/pixi-build-bazel && cargo build)
export PIXI_BUILD_BACKEND_OVERRIDE="pixi-build-bazel=$(realpath ../../backends/pixi-build-bazel/target/debug/pixi-build-bazel)"
export BAZEL=/path/to/bazelisk

# inside the repository
pixi run greet          # Hello, monorepo! (crc32 …, zlib 1.3.2)
pixi run py-greet       # Hello, python! …

# outside the repository
cd ../monorepo-consumer
pixi run greet
pixi run py-greet       # same packages, on Python 3.13
```

What happens: pixi asks the backend for the outputs of `..` (or `.`). The
backend runs one `bazel cquery` over all `conda_package` targets (analysis
only) and reports all three packages. pixi then solves the environment, which
pulls `libgreet` in as a dependency of the other two, and calls
`conda/build_v1` for each package it needs. Each call is a `bazel build`.

Note: pixi doesn't notice source edits on its own yet; the build string is
derived from metadata, not file contents. After changing code, run
`pixi reinstall greet-cli py-greet libgreet` (`try.sh` does this for you).

Plain Bazel works the same without pixi: `bazel build //...` produces the
three `.conda` files, and `bazel run //greet-cli:greet` runs the binary.

## Why `third_party/` has its own lock

The conda packages Bazel *compiles against* (`@conda//zlib`) are locked in
`third_party/pixi.lock`. If they lived in the monorepo's own `pixi.lock`,
solving the workspace would need Bazel's dry run, and the dry run would need
that same lock. A separate lock breaks the cycle. Bazel reads it the same way
in standalone builds and under pixi (`host-environment = "lock"`, the
backend's default).
