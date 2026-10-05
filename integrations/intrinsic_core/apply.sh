#!/usr/bin/env bash
# Wire rules_rattler into an intrinsic-core checkout.
#   ./apply.sh /path/to/intrinsic-core
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
rules="$(cd "$here/../.." && pwd)"
ic="$1"

mkdir -p "$ic/packaging/conda"
cp "$here/BUILD.bazel" "$here/apis_targets.bzl" "$here/defs.bzl" "$here/pixi.toml" "$here/pixi.lock" "$ic/packaging/conda/"

if ! grep -q rules_rattler "$ic/MODULE.bazel"; then
  cat >> "$ic/MODULE.bazel" <<MOD

# --- conda packaging (rules_rattler) ---
bazel_dep(name = "rules_rattler", version = "0.0.0")
local_path_override(module_name = "rules_rattler", path = "$rules")

# Until rules_rattler ships release binaries: use a local build
# (cargo build --release in tools/conda_builder).
conda_builder = use_extension("@rules_rattler//conda:extensions.bzl", "conda_builder")
conda_builder.local(path = "$rules/tools/conda_builder/target/release/conda_builder")

# Locked host environment (python for the pybind11 extensions).
pixi = use_extension("@rules_rattler//conda:extensions.bzl", "pixi")
pixi.workspace(name = "conda", lock = "//packaging/conda:pixi.lock")
use_repo(pixi, "conda")
MOD
fi

# Only packaging builds use the locked python (`bazel build --config=conda`);
# everything else keeps upstream's toolchains.
if ! grep -q "config=conda\|^build:conda" "$ic/.bazelrc"; then
  printf '\n# rules_rattler: build against the pixi.lock host environment\nbuild:conda --extra_toolchains=@conda//:all\n' >> "$ic/.bazelrc"
fi
