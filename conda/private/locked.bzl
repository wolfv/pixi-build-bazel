"""`conda_locked_package`: the Bazel face of one package from a pixi.lock.

Generated into the environment repositories by the `pixi` module extension.
Forwards the Python / C++ view of the package (if it has one) and adds
`CondaDepInfo`, which packaging rules use to derive run requirements.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_python//python:py_info.bzl", "PyInfo")
load("//conda:providers.bzl", "CondaDepInfo")

def _conda_locked_package_impl(ctx):
    # Runfiles carry the whole runtime closure (extension modules, shared
    # libraries of dependencies, ...), not just the PyInfo sources.
    runfiles = ctx.runfiles(files = ctx.files.files).merge_all([
        t[DefaultInfo].default_runfiles
        for t in [ctx.attr.py] + ctx.attr.deps
        if t
    ])
    providers = [
        DefaultInfo(files = depset(ctx.files.files), runfiles = runfiles),
        CondaDepInfo(
            name = ctx.attr.package_name,
            version = ctx.attr.version,
            build = ctx.attr.build,
            run_exports = ctx.attr.run_exports,
        ),
    ]
    if ctx.attr.py:
        providers.append(ctx.attr.py[PyInfo])
    # Always present (empty for packages without C/C++ content): rules_cc's
    # graph aspect (cc_shared_library) only visits rules that declare CcInfo.
    providers.append(cc_common.merge_cc_infos(cc_infos = [d[CcInfo] for d in ctx.attr.deps]))
    return providers

conda_locked_package = rule(
    implementation = _conda_locked_package_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "build": attr.string(mandatory = True),
        "run_exports": attr.string_list(),
        "files": attr.label_list(allow_files = True),
        "py": attr.label(providers = [PyInfo]),
        # Named `deps` so cc_shared_library's graph aspect sees the libraries
        # (it only walks `deps`-like attributes).
        "deps": attr.label_list(providers = [CcInfo], doc = "The cc_library view of the package (at most one)."),
    },
    provides = [CondaDepInfo, CcInfo],
)
