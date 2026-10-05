"""Module extensions: prebuilt tools (`rattler-build`, `conda_builder`), pixi.lock deps, pixi build context."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")
load("//conda/private:pixi.bzl", _pixi = "pixi")

_VERSION = "0.74.0"

# conda subdir -> (release asset, sha256, os constraint, cpu constraint)
_BINARIES = {
    "linux-64": ("rattler-build-x86_64-unknown-linux-musl", "a38fab4bc5a8fe1ade3d0c5e37ede2cef39c89fd9c082c8032ebbb8443259de2", "linux", "x86_64"),
    "linux-aarch64": ("rattler-build-aarch64-unknown-linux-musl", "fd14ce4ec375e63f217fc33f39edb238c568eaaac62e13fc300c7c58c19c1505", "linux", "aarch64"),
    "osx-64": ("rattler-build-x86_64-apple-darwin", "39a053b0318afbe1f349f15f29b6a1df9c327cfb1a9933b3e6a4699b04b05f80", "macos", "x86_64"),
    "osx-arm64": ("rattler-build-aarch64-apple-darwin", "85efdc0c4867f5dc38f56be03d2c4071da702de228dee2dd200a5b83469c28ad", "macos", "aarch64"),
    "win-64": ("rattler-build-x86_64-pc-windows-msvc.exe", "00a24ea3d1538bca6e9b6120c29c9b3988d709697d4335f0d3ef8308461ad103", "windows", "x86_64"),
}

def _repo_name(subdir):
    return "rattler_build_" + subdir.replace("-", "_")

# Static patchelf, put on PATH for rattler-build: Bazel's rpaths often need
# more room than the in-place relinker has. subdir -> (asset, sha256, cpu)
_PATCHELF_VERSION = "0.19.2"
_PATCHELF = {
    "linux-64": ("patchelf-0.19.2-x86_64.tar.gz", "2abdc34fbe949c995a1baa4ec310896a085588a45a99cd0d726851bdfac2a4bb", "x86_64"),
    "linux-aarch64": ("patchelf-0.19.2-aarch64.tar.gz", "ba6850c1a6f4cbdb050e1cc22fa5239159ad31c43606846e49c408d335f594ff", "aarch64"),
}

def _patchelf_repo_name(subdir):
    return "patchelf_" + subdir.replace("-", "_")

def _hub_impl(rctx):
    lines = ['package(default_visibility = ["//visibility:public"])', ""]
    for subdir, (_, _, os, cpu) in _BINARIES.items():
        lines.append('config_setting(name = "{}", constraint_values = ["@platforms//os:{}", "@platforms//cpu:{}"])'.format(subdir, os, cpu))
    lines.append("")

    if rctx.attr.local_path:
        # A locally built rattler-build (e.g. with unreleased features).
        rctx.symlink(rctx.attr.local_path, "bin/rattler-build")
        lines.append('alias(\n    name = "rattler_build",\n    actual = "bin/rattler-build",\n)')
    else:
        items = "".join(['        ":{}": "@{}//file",\n'.format(sd, _repo_name(sd)) for sd in _BINARIES])
        lines.append('alias(\n    name = "rattler_build",\n    actual = select({\n' + items + "    }),\n)")

    # Only needed (and only available) on Linux; elsewhere a stub keeps the
    # label valid.
    rctx.file("bin/patchelf-unavailable", "#!/bin/sh\necho 'patchelf is only provided for Linux' >&2\nexit 1\n", executable = True)
    items = "".join(['        ":{}": "@{}//:bin/patchelf",\n'.format(sd, _patchelf_repo_name(sd)) for sd in _PATCHELF])
    lines.append('alias(\n    name = "patchelf",\n    actual = select({\n' + items + '        "//conditions:default": "bin/patchelf-unavailable",\n    }),\n)')
    rctx.file("BUILD.bazel", "\n".join(lines) + "\n")

_hub = repository_rule(
    implementation = _hub_impl,
    attrs = {"local_path": attr.string()},
    # A local binary can change without the path changing.
    local = True,
)

def _rattler_build_impl(mctx):
    local_path = ""
    for mod in mctx.modules:
        if mod.is_root:
            for tag in mod.tags.local:
                local_path = tag.path
    for subdir, (asset, sha256, _, _) in _BINARIES.items():
        http_file(
            name = _repo_name(subdir),
            urls = ["https://github.com/prefix-dev/rattler-build/releases/download/v{}/{}".format(_VERSION, asset)],
            sha256 = sha256,
            executable = True,
            downloaded_file_path = "rattler-build.exe" if asset.endswith(".exe") else "rattler-build",
        )
    for subdir, (asset, sha256, _) in _PATCHELF.items():
        http_archive(
            name = _patchelf_repo_name(subdir),
            urls = ["https://github.com/NixOS/patchelf/releases/download/{}/{}".format(_PATCHELF_VERSION, asset)],
            sha256 = sha256,
            build_file_content = 'exports_files(["bin/patchelf"])\n',
        )
    _hub(name = "rattler_build", local_path = local_path)
    return mctx.extension_metadata(reproducible = True)

rattler_build = module_extension(
    implementation = _rattler_build_impl,
    tag_classes = {"local": tag_class(attrs = {"path": attr.string(mandatory = True, doc = "Absolute path to a rattler-build binary.")})},
    doc = """Provides `@rattler_build`, used to create packages (`rattler-build package create`) and to upload them.

`conda_package` needs a rattler-build with the `package create` subcommand; until that is released,
the root module points at a local build with `rattler_build.local(path = ...)`.""",
)

# ---- pixi build context -----------------------------------------------------

def _pixi_context_repo_impl(rctx):
    rctx.file("BUILD.bazel", 'exports_files(["overrides.bzl"])\n')
    overrides = json.decode(rctx.attr.overrides) if rctx.attr.overrides else {}
    rctx.file("overrides.bzl", "# Generated: package metadata decided by pixi (pixi-build-bazel).\nPIXI_OVERRIDES = {}\n".format(
        json.encode_indent(overrides) if overrides else "{}",
    ))

_pixi_context_repo = repository_rule(
    implementation = _pixi_context_repo_impl,
    attrs = {"overrides": attr.string()},
)

def _pixi_build_context_impl(mctx):
    # Set by pixi-build-bazel for `conda/build_v1`: a JSON file mapping package
    # name -> {"build": ..., "depends": [...], "constrains": [...]}.
    path = mctx.getenv("RULES_RATTLER_PIXI_OVERRIDES", "")
    # The file name is content-addressed, so the env var changes with it.
    overrides = mctx.read(mctx.path(path), watch = "no") if path else ""
    _pixi_context_repo(name = "rules_rattler_pixi_context", overrides = overrides)
    return mctx.extension_metadata(reproducible = True)

pixi_build_context = module_extension(
    implementation = _pixi_build_context_impl,
    doc = "Internal: lets pixi-build-bazel inject the final package metadata pixi computed.",
)

# ---- conda_builder --------------------------------------------------------

# TODO: fill in once rules_rattler publishes release binaries.
# conda subdir -> (url, sha256)
_CONDA_BUILDER_RELEASES = {}

def _host_subdir(rctx):
    os = rctx.os.name.lower()
    arch = rctx.os.arch
    if os.startswith("linux"):
        return "linux-aarch64" if arch in ("aarch64", "arm64") else "linux-64"
    if os.startswith("mac"):
        return "osx-arm64" if arch in ("aarch64", "arm64") else "osx-64"
    if os.startswith("windows"):
        return "win-64"
    fail("unsupported host: {} {}".format(os, arch))

def _conda_builder_repo_impl(rctx):
    exe = "conda_builder.exe" if rctx.os.name.lower().startswith("windows") else "conda_builder"
    if rctx.attr.path:
        rctx.symlink(rctx.attr.path, "bin/" + exe)
    else:
        subdir = _host_subdir(rctx)
        if subdir not in _CONDA_BUILDER_RELEASES:
            # Keep the repo loadable so builds that don't package anything
            # still work; fail only when the tool actually runs.
            rctx.file("bin/" + exe, "#!/bin/sh\necho 'rules_rattler: no prebuilt conda_builder for {}; use conda_builder.local(path = ...)' >&2\nexit 1\n".format(subdir), executable = True)
        else:
            url, sha256 = _CONDA_BUILDER_RELEASES[subdir]
            rctx.download(url, "bin/" + exe, sha256 = sha256, executable = True)
    rctx.file("BUILD.bazel", """
alias(
    name = "conda_builder",
    actual = "bin/{}",
    visibility = ["//visibility:public"],
)
""".format(exe))

_conda_builder_repo = repository_rule(
    implementation = _conda_builder_repo_impl,
    attrs = {"path": attr.string()},
    # A local binary can change without the path changing.
    local = True,
)

_local = tag_class(attrs = {"path": attr.string(mandatory = True, doc = "Absolute path to a conda_builder binary.")})

def _conda_builder_impl(mctx):
    path = ""
    for mod in mctx.modules:
        if mod.is_root:
            for tag in mod.tags.local:
                path = tag.path
    _conda_builder_repo(name = "conda_builder", path = path)

conda_builder = module_extension(
    implementation = _conda_builder_impl,
    tag_classes = {"local": _local},
    doc = "Provides `@conda_builder`. The root module can point it at a local build with `conda_builder.local(path = ...)`.",
)

# ---- pixi.lock --------------------------------------------------------------

pixi = _pixi
