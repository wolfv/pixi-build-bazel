"""Map the Bazel target platform onto a conda subdir."""

# (os constraint attr, cpu constraint attr) -> subdir
_SUBDIRS = [
    ("_os_linux", "_cpu_x86_64", "linux-64"),
    ("_os_linux", "_cpu_aarch64", "linux-aarch64"),
    ("_os_linux", "_cpu_ppc64le", "linux-ppc64le"),
    ("_os_macos", "_cpu_x86_64", "osx-64"),
    ("_os_macos", "_cpu_aarch64", "osx-arm64"),
    ("_os_windows", "_cpu_x86_64", "win-64"),
    ("_os_windows", "_cpu_aarch64", "win-arm64"),
]

SUBDIR_ATTRS = {
    "_os_linux": attr.label(default = "@platforms//os:linux"),
    "_os_macos": attr.label(default = "@platforms//os:macos"),
    "_os_windows": attr.label(default = "@platforms//os:windows"),
    "_cpu_x86_64": attr.label(default = "@platforms//cpu:x86_64"),
    "_cpu_aarch64": attr.label(default = "@platforms//cpu:aarch64"),
    "_cpu_ppc64le": attr.label(default = "@platforms//cpu:ppc64le"),
}

def _has(ctx, attr_name):
    return ctx.target_platform_has_constraint(
        getattr(ctx.attr, attr_name)[platform_common.ConstraintValueInfo],
    )

def target_subdir(ctx):
    """Returns the conda subdir for the current target platform.

    Args:
        ctx: rule context of a rule that includes SUBDIR_ATTRS.
    Returns:
        The subdir string, e.g. "linux-64".
    """
    for os_attr, cpu_attr, subdir in _SUBDIRS:
        if _has(ctx, os_attr) and _has(ctx, cpu_attr):
            return subdir
    fail("{}: cannot map the target platform to a conda subdir; set `subdir` explicitly".format(ctx.label))
