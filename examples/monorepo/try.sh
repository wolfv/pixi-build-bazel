#!/usr/bin/env bash
# Try the Bazel monorepo -> conda packages -> pixi example end to end.
#
#   ./try.sh            build everything and run the demo
#   ./try.sh --fresh    first remove the pixi environments and the consumer's lock
#   ./try.sh --bazel    only the plain Bazel part (no pixi)
#
# Needs: pixi, cargo. Uses $BAZEL or `bazelisk` from PATH, or downloads a
# pinned bazelisk into ~/.cache/rules_rattler.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
consumer="$repo/examples/monorepo-consumer"

fresh=false
bazel_only=false
for arg in "$@"; do
  case "$arg" in
    --fresh) fresh=true ;;
    --bazel) bazel_only=true ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

bold=$'\e[1m' dim=$'\e[2m' green=$'\e[32m' red=$'\e[31m' reset=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$bold" "$*" "$reset"; }
info() { printf '%s    %s%s\n' "$dim" "$*" "$reset"; }
die() { printf '%serror:%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }
# Hide Bazel's progress chatter; keep errors and program output.
quiet() { grep -vE '^(Computing|Loading|Analyzing|INFO:|Target |  bazel-bin|WARNING: .*restricted|\s*$)' || true; }

# --- prerequisites -----------------------------------------------------------

step "Checking prerequisites"
command -v pixi >/dev/null || die "pixi not found (https://pixi.sh)"
command -v cargo >/dev/null || die "cargo not found (https://rustup.rs)"
info "pixi $(pixi --version | cut -d' ' -f2), $(cargo --version)"

# Bazel: $BAZEL, else bazelisk on PATH, else a pinned bazelisk download.
# (conda-forge has `bazel` but not `bazelisk`; its wrapper forces --batch
# mode, which loses Bazel's server between the backend's calls.)
if [[ -z "${BAZEL:-}" ]]; then
  if command -v bazelisk >/dev/null; then
    BAZEL="$(command -v bazelisk)"
  else
    version=v1.29.0
    case "$(uname -s)-$(uname -m)" in
      Linux-x86_64) asset=bazelisk-linux-amd64 sha=5a408715e932c0250d28bd84555f12edbf70117de42f9181691c736eacc4a992 ;;
      Linux-aarch64) asset=bazelisk-linux-arm64 sha=e20e8b0f4f240091b7a55bf17b9398bd4f40ee70ae0208dff95dd4c445fb4010 ;;
      Darwin-x86_64) asset=bazelisk-darwin-amd64 sha=16c3d7aa15323a9fb69f56c7ec5733ed18bedb786680d0ba13bb12a3c8083007 ;;
      Darwin-arm64) asset=bazelisk-darwin-arm64 sha=cee851f726789227d5561004e9904a52be45c3efb56f8b38b6993d6adbaa0409 ;;
      *) die "no bazelisk download for $(uname -s)-$(uname -m); set BAZEL" ;;
    esac
    BAZEL="${XDG_CACHE_HOME:-$HOME/.cache}/rules_rattler/bazelisk-$version"
    if [[ ! -x "$BAZEL" ]]; then
      info "downloading bazelisk $version"
      mkdir -p "$(dirname "$BAZEL")"
      curl -fsSL -o "$BAZEL.tmp" "https://github.com/bazelbuild/bazelisk/releases/download/$version/$asset"
      echo "$sha  $BAZEL.tmp" | sha256sum -c --quiet - || die "bazelisk checksum mismatch"
      chmod +x "$BAZEL.tmp" && mv "$BAZEL.tmp" "$BAZEL"
    fi
  fi
fi
export BAZEL
info "bazel: $BAZEL (version from $here/.bazelversion: $(cat "$here/.bazelversion"))"

# rattler-build (released, sha-pinned) and patchelf are fetched by Bazel itself.

# --- plain Bazel ---------------------------------------------------------------

step "Plain Bazel: bazel build //... (three .conda packages)"
cd "$here"
"$BAZEL" build //... 2>&1 | quiet
for pkg in libgreet greet-cli py-greet; do
  # Newest file per package (older builds may still be around).
  f="$(ls -t bazel-bin/"$pkg"/"$pkg"-*.conda | head -1)"
  deps="$(unzip -p "$f" 'info-*' | tar --zstd -xO info/index.json |
    python3 -c 'import json,sys; print(", ".join(json.load(sys.stdin)["depends"]))')"
  printf '    %s%-40s%s depends: %s\n' "$green" "$(basename "$f")" "$reset" "$deps"
done

step "Plain Bazel: bazel run //greet-cli:greet"
"$BAZEL" run //greet-cli:greet -- bazel 2>&1 | quiet

$bazel_only && exit 0

# --- pixi ------------------------------------------------------------------------

step "Building the pixi-build-bazel backend"
(cd "$repo/backends/pixi-build-bazel" && cargo build --quiet)
export PIXI_BUILD_BACKEND_OVERRIDE="pixi-build-bazel=$repo/backends/pixi-build-bazel/target/debug/pixi-build-bazel"
info "PIXI_BUILD_BACKEND_OVERRIDE=$PIXI_BUILD_BACKEND_OVERRIDE"

if $fresh; then
  step "Removing pixi environments (--fresh)"
  (cd "$here" && pixi clean >/dev/null 2>&1 || true)
  (cd "$consumer" && pixi clean >/dev/null 2>&1 || true; rm -f "$consumer/pixi.lock")
fi

# pixi doesn't notice source edits on its own (the build string is derived
# from metadata, not file contents), so rebuild the source packages
# explicitly. Bazel makes this cheap when nothing changed.
rebuild() { pixi reinstall greet-cli py-greet libgreet 2>&1 | quiet | grep -v "^✔" || true; }

step "pixi workspace INSIDE the repo ($here)"
info "pixi asks Bazel for all conda outputs, then builds greet-cli, py-greet and libgreet"
cd "$here"
rebuild
pixi run greet 2>&1 | quiet
pixi run py-greet 2>&1 | quiet
pixi list 2>/dev/null | grep -E '^(Name|greet|libgreet|py-greet|libzlib)' | sed 's/^/    /'

step "pixi workspace OUTSIDE the repo ($consumer)"
cd "$consumer"
rebuild
pixi run greet 2>&1 | quiet
pixi run py-greet 2>&1 | quiet
pixi list 2>/dev/null | grep -E '^(Name|greet|libgreet|py-greet|libzlib|python )' | sed 's/^/    /'

step "Relocatable binaries"
env="$consumer/.pixi/envs/default"
rpath() { readelf -d "$1" | sed -n 's/.*R\(UN\)\{0,1\}PATH.*\[\(.*\)\]/\2/p'; }
printf '    bin/greet         rpath %s\n' "$(rpath "$env/bin/greet")"
printf '    lib/libgreet.so   rpath %s\n' "$(rpath "$env/lib/libgreet.so")"

printf '\n%sDone.%s Try editing libgreet/greet.cc and re-running ./try.sh.\n' "$green$bold" "$reset"
