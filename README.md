# rules_rattler

Bazel rules that produce **conda packages** (`.conda`) as build outputs, the
way `rules_oci` produces OCI images. Packages are created by rattler-build,
which relinks binaries, writes `info/` and archives.
By default the rule generates a regular rattler-build **recipe** (JSON) whose
build script copies the staged files into `$PREFIX`, and runs the released,
sha-pinned rattler-build (with a pinned `patchelf` for relinking). Nothing
needs to be installed by hand.

`--@rules_rattler//conda:packager=package-create` switches to
`rattler-build package create` with a JSON manifest. That mode produces
byte-for-byte reproducible archives (recipe builds stamp the build time),
but it needs an unreleased rattler-build (branch `feat/package-from-json`,
via `rattler_build.local(path = ...)`).

There is also an experimental **pixi build backend**
([`backends/pixi-build-bazel`](backends/pixi-build-bazel)). It makes every
`conda_package` target of a Bazel workspace a conda output that pixi can
build from source.

## Try it in your own Bazel workspace

1. `MODULE.bazel`:

   ```starlark
   bazel_dep(name = "rules_rattler", version = "0.0.0")
   git_override(
       module_name = "rules_rattler",
       remote = "https://github.com/wolfv/pixi-build-bazel",
       branch = "main",  # or a release tag / commit
   )
   ```

2. Add `conda_package` targets (see below and `examples/monorepo`).

3. `pixi.toml` at the workspace root. Every `conda_package` target becomes
   a conda output that pixi can build:

   ```toml
   [workspace]
   channels = ["conda-forge"]
   platforms = ["linux-64"]
   preview = ["pixi-build"]

   [package]
   name = "my-monorepo"
   version = "0.1.0"

   [package.build]
   backend = { name = "pixi-build-bazel", version = "*", channels = ["https://prefix.dev/wolfv/experiments", "conda-forge"] }

   [dependencies]
   my-tool = { path = "." }   # any conda_package target's package name
   ```

   pixi installs the backend together with `bazelisk`, which runs the Bazel
   version from your `.bazelversion`. Point it at your own launcher with
   `[package.build.config] bazel = "./bazelw"`.

## Example

```starlark
load("@rules_pkg//pkg:mappings.bzl", "pkg_files")
load("@rules_rattler//conda:defs.bzl", "conda_channel", "conda_package", "conda_upload")

pkg_files(name = "data", srcs = ["greeting.txt"], prefix = "share/hello")

conda_package(
    name = "hello-data",
    version = "1.0.0",
    noarch = "generic",
    srcs = [":data"],
)

conda_package(
    name = "hello-cc",
    version = "1.0.0",
    bins = [":hello"],                  # cc_binary -> bin/hello
    depends = ["libstdcxx >=13"],       # external deps: MatchSpecs
    deps = [":hello-data"],             # in-repo deps: labels, pinned automatically
    license = "MIT",
)

conda_channel(name = "channel", packages = [":hello-cc"])   # file:// channel + repodata.json

conda_upload(                                               # bazel run :upload
    name = "upload",
    packages = [":hello-cc"],
    server = "prefix",
    args = ["--channel", "my-channel", "--skip-existing"],
)
```

Try it:

```sh
pixi run bazel build //examples/...
pixi exec -c file://$(pixi run bazel info bazel-bin)/examples/hello/channel -c conda-forge -s hello-cc hello
```

## Rules

| Rule | Output |
| --- | --- |
| `conda_package` | `<name>-<version>-<build>.conda`, plus `CondaPackageInfo` |
| `conda_python_package` | `noarch: python` package from `py_library` / `py_proto_library` targets |
| `conda_channel` | a channel directory: `<subdir>/*.conda` + `repodata.json` (noarch always present) |
| `conda_upload` | executable that runs `rattler-build upload <server> ...` (prebuilt, sha-pinned binary) |

### Where package content comes from

* `srcs`: plain targets (placed under `prefix`), or rules_pkg `pkg_files`,
  `pkg_filegroup` and `pkg_mklink` for full control over paths, modes and symlinks.
* `bins`: executables, installed into `bin/` (`Library/bin/` on Windows).
* `symlinks`: `{"path/in/pkg": "target"}`.

### Dependencies

* `depends` / `constrains`: MatchSpec strings for packages from other channels.
* `deps`: labels of other `conda_package` targets. The rule turns them into run
  requirements using `pin`, which can be `version` (default, `name ==1.2.3`),
  `exact` (adds the build string), `compatible` (`>=1.2.3,<2`) or `name`. They
  are also tracked transitively, so `conda_channel` and `conda_upload` pick them up.
* `run_exports`: weak run exports written to `info/run_exports.json`.

### Python

`conda_python_package(py_deps = [...])` walks the `PyInfo` closure and sorts each
file by the Bazel repository that owns it:

* main repo (+ `bundle`): copied to `site-packages/`, using the targets' import roots;
* rules_python pip repos: *direct* pip deps of first-party code become run
  requirements (`pypi_to_conda` renames/pins);
* other modules must be mapped in `repo_map` (MatchSpec, `"bundle"`, or `""`);
  unmapped ones fail with a list of example files;
* files already shipped by in-repo conda `deps` are skipped, so one Bazel graph
  can be split into several packages.

### Conda dependencies from pixi.lock

```starlark
# MODULE.bazel
pixi = use_extension("@rules_rattler//conda:extensions.bzl", "pixi")
pixi.workspace(name = "conda", lock = "//:pixi.lock")
use_repo(pixi, "conda")
register_toolchains("@conda//:all")   # the locked python becomes the Python toolchain
```

```starlark
py_library(name = "stats", srcs = ["stats.py"], deps = ["@conda//numpy"])
cc_binary(name = "zversion", srcs = ["zversion.cc"], deps = ["@conda//zlib"])
```

* The lock is parsed in Starlark. Nothing is solved at build time, and downloads are
  pinned by sha256.
* Each locked platform becomes one repository holding the whole environment as a
  real prefix (text prefix placeholders replaced), so rpaths between packages work.
  `@conda//<pkg>` picks the right one with `select()`.
* Every package target provides `PyInfo` (site-packages) and/or `CcInfo` (`include/`,
  `lib/*.so`), plus runfiles for its runtime closure.
* **Run requirements are derived from these edges:** `conda_python_package` depends on
  locked packages by name (`numpy`). `conda_package` uses the `run_exports` of the
  packages its `bins`/`srcs` link against (`libzlib >=1.3.2,<2.0a0`), the way
  rattler-build handles host dependencies.
* ELF files get their RUNPATH rewritten from Bazel's `_solib` paths to
  `$ORIGIN/../lib` when packaged, so installed binaries use the env's libraries.

### Platform / subdir

The subdir comes from the Bazel **target platform** (`@platforms//os` +
`@platforms//cpu`). `bazel build --platforms=//:macos_arm64` produces an
`osx-arm64` package. `noarch = "generic"` or an explicit `subdir` overrides it.

The build string defaults to `h<hash>_<build_number>`. The hash covers subdir,
depends, constrains and track_features, so different variants never collide.

## Layout

```
conda/defs.bzl                  public API
conda/private/*.bzl             rule implementations
conda/extensions.bzl            rattler-build (local or prebuilt), pixi.lock deps, pixi build context
conda/platforms/                one Bazel platform per conda subdir
tools/conda_builder/            Rust tool used by conda_channel (`index`)
backends/pixi-build-bazel/      experimental pixi build backend (see its README)
examples/                       C++ binary + noarch data, cross-platform script, split Python packages
examples/pixi_build/            a Bazel workspace built by pixi through pixi-build-bazel
examples/monorepo/              monorepo with 3 packages (C shared lib, CLI, Python), used by pixi
examples/monorepo-consumer/     ... and from a pixi workspace outside the repository
integrations/intrinsic_core/    packaging Intrinsic Core from source (see its README)
```

## Not done yet / ideas

* **Release `rattler-build package create`** (branch `feat/package-from-json`)
  and make it the default packager: reproducible archives, faster, and no
  shell script (recipe mode is Unix-only for now). `conda_channel` still uses
  `conda_builder index`. Moving indexing into rattler-build as well would
  remove the custom tool entirely. Both should become proper toolchains
  (exec-platform aware) for remote execution.
* **Prefix detection** is off for Bazel outputs (they don't embed a conda
  build prefix); the manifest's `detect_prefix` can turn it on.
* **macOS:** the in-place rpath clean-up (`strip_rpath_patterns`) is
  ELF-only so far.
* **Runfiles.** `bins` packages only the executable. `py_binary` and other
  targets with runfiles need a dedicated mapping, such as a `noarch: python`
  helper with entry points.
* **pixi.lock follow-ups:** PyPI packages from the lock, Windows (`Library/`)
  layouts, a conda-forge compiler toolchain (today `cc_*` uses the host compiler,
  so there's no `libstdcxx`/`__glibc` pinning), Mach-O rpath rewriting for macOS,
  and binary-mode prefix placeholders.
* **OCI integration.** Use `conda_channel` output (or an installed env) as a
  `rules_oci` layer.
* TreeArtifact (directory) inputs, and Windows support for the `conda_upload` script.
