# pixi-build-bazel (experimental)

A pixi build backend for Bazel workspaces. Every `conda_package` target
(rules_rattler) in the workspace is a conda output. pixi picks the outputs it
needs, and the backend builds them with Bazel.

```
pixi                           pixi-build-bazel                    bazel
 │ conda/outputs ───────────▶  dry run:  bazel cquery 'kind(conda_package, //...)'
 │ ◀── all outputs              (analysis only, reads CondaPackageInfo)
 │ solve; pick outputs, install host env
 │ conda/build_v1 (per output) ▶ bazel build //pkg:target
 │                                 --repo_env=RULES_RATTLER_PIXI_HOST_PREFIX=<pixi host env>
 │                                 --repo_env=RULES_RATTLER_PIXI_OVERRIDES=<final depends, build string>
 │ ◀── .conda
```

## Who provides the build environment: `host-environment`

| | `lock` (default) | `pixi` |
|---|---|---|
| `@conda//...` comes from | the workspace's `pixi.lock` (a dedicated environment, e.g. `host`), read by Bazel | a host environment pixi solves and installs per output |
| reported to pixi | final run requirements (lock run_exports already applied), no host/build deps | run requirements + `@conda` packages as host deps |
| pixi installs for the build | nothing (it only creates empty prefix directories) | the host environment |
| same as standalone `bazel build` | yes | no |

`lock` keeps Bazel in charge and hermetic. pixi only decides *which* outputs
to build and how they fit the consumer's environment. `pixi` lets pixi
re-solve the host environment for the consumer's channels and platform.

The example keeps both roles in one manifest:

```toml
[package.build.config]
host-environment = "lock"

[feature.host.dependencies]
zlib = "*"

[environments]
host = { features = ["host"], no-default-feature = true }
```

```starlark
# MODULE.bazel
pixi.workspace(name = "conda", lock = "//:pixi.lock", environment = "host")
```

## What maps to what

| `conda_package` | conda output |
|---|---|
| name / version / build string / subdir / noarch | metadata (the build string is computed by Bazel) |
| `depends`, Python/pip-derived requirements | run dependencies |
| `deps = [":other_pkg"]` | run dependency on a **sibling output** (`path: "."`) |
| locked `@conda//pkg` it links against | its run_exports in the run deps (`lock`), or a **host** dependency (`pixi`) |
| `run_exports` | run exports |

In `pixi` mode, `conda/build_v1` points the `@conda` repositories at the
host environment pixi installed, instead of the workspace's own pixi.lock. In
both modes, the final run requirements and build string written into
`index.json` are the ones pixi passed in.

## Configuration

```toml
[package.build]
backend = { name = "pixi-build-bazel", version = "*" }

[package.build.config]
bazel = "./bazelw"          # default: $BAZEL, then the bundled bazelisk, then `bazel`
targets = "//packages/..."  # default: //...
bazel-args = ["--config=ci"]
host-environment = "lock"   # or "pixi", see above
```

## Installing

The backend is published to `https://prefix.dev/wolfv/experiments` together
with `bazelisk` (a run dependency):

```toml
[package.build]
backend = { name = "pixi-build-bazel", version = "*", channels = ["https://prefix.dev/wolfv/experiments", "conda-forge"] }
```

It speaks the build protocol of pixi v0.76 (`pixi-build-api-version 6`).

## Developing

```sh
cargo build                               # in this directory
export PIXI_BUILD_BACKEND_OVERRIDE="pixi-build-bazel=$PWD/target/debug/pixi-build-bazel"
export BAZEL=/path/to/bazelisk            # the official binary; conda-forge's wrapper needs its env's Java
cd ../../examples/pixi_build/consumer && pixi run zversion
```

The consumer depends only on `zversion`. pixi builds `zversion` and its
sibling `greeting-data`, and never builds `unused-tool`. It installs
`libzlib` from conda-forge because of zlib's run_exports.

## Limitations

- Pinned to the protocol of pixi v0.76.1 (`pixi_build_types` from that tag,
  `pixi-build-api-version >=6,<7`); newer pixi releases that dropped API
  version 6 won't load it.
- pixi's input globs cover only the workspace directory. Changes to modules
  outside it (e.g. a `local_path_override`) don't invalidate pixi's cached
  metadata, so run `pixi clean` after changing them.
- No variants yet. In `pixi` mode only the host environment comes from pixi;
  the build environment (e.g. conda-forge compilers as a Bazel cc toolchain)
  is not used yet.
- In `lock` mode the consumer's platform must be one of the platforms locked
  for the Bazel workspace's host environment.
- Cross builds use `--platforms=@rules_rattler//conda/platforms:<subdir>`. They
  need a C/C++ toolchain for that platform in the workspace.
