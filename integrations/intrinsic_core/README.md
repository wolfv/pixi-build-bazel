# Intrinsic Core → conda, built by Bazel

Builds conda packages from source inside the upstream intrinsic-core Bazel
workspace (Bazel 8.8, upstream's own toolchains), replacing the rattler-build
recipes in `intrinsic-core-conda`.

| Package | Source | Notes |
|---|---|---|
| `inctl` | `//intrinsic/tools/inctl:inctl_external` (go_binary) | cgo binary → `__glibc >=2.29` |
| `intrinsic-apis-python` | all `py_proto_library` / `py_grpc_library` of `@intrinsic_apis` | noarch: python |
| `intrinsic-sdk-python` | `intrinsic.solutions` targets | depends on `intrinsic-apis-python`; ships only what that doesn't |

Run requirements are derived from the Bazel graph: direct pip deps of first-party
code and external modules (`protobuf`, `grpc`, `googleapis`, ...) via `defs.bzl`.

```sh
(cd ../../tools/conda_builder && cargo build --release)   # until release binaries exist
./apply.sh /path/to/intrinsic-core                         # adds packaging/conda + MODULE.bazel lines
cd /path/to/intrinsic-core && bazel build //packaging/conda:channel
pixi exec -c file://$(readlink -f bazel-bin/packaging/conda/channel) -c conda-forge \
    -s intrinsic-sdk-python -s inctl -- python -c "import intrinsic.solutions.deployments"
```

## Findings (20260922.0)

* 11 proto targets in `intrinsic_apis` reference `.proto` files missing from the
  release tarball; they (and their rdeps) are excluded in `apis_targets.bzl`.
* `googleapis-common-protos` 1.75 registers `google/longrunning/operations.proto`
  under a different name, breaking every module importing it (this also breaks the
  current rattler-build package). Pinned `<1.75`.
* `inctl` is built in fastbuild without stamping: 110 MB unstripped and `version`
  reports `unknown`. Use `-c opt --stamp` (and upstream's version x_defs) for releases.
* Only the closure of the listed `py_deps` is packaged (419 modules, all import);
  the old recipe compiled every `.proto`. Add targets to `py_deps` to widen it.
* pybind11/C++ modules are not packaged yet.
