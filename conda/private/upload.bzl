"""Implementation of `conda_upload`."""

load(":channel.bzl", "collect_packages")
load("//conda:providers.bzl", "CondaPackageInfo")

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def _conda_upload_impl(ctx):
    packages = collect_packages(ctx.attr.packages, ctx.attr.transitive)
    rb = ctx.executable._rattler_build
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, is_executable = True, content = """#!/usr/bin/env bash
set -euo pipefail
# `bazel run` executes from the runfiles tree of the main repository.
# "$@" carries the target's `args` attribute plus anything after `--`.
exec {rb} upload {server} "$@" {packages}
""".format(
        rb = _shell_quote(rb.short_path),
        server = _shell_quote(ctx.attr.server),
        packages = " ".join([_shell_quote(p.short_path) for p in packages]),
    ))
    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = packages + [rb]),
    )]

conda_upload = rule(
    implementation = _conda_upload_impl,
    executable = True,
    doc = """`bazel run` target that uploads packages with `rattler-build upload`.

Example:

    conda_upload(
        name = "publish",
        packages = [":mypkg"],
        server = "prefix",
        args = ["--channel", "my-channel", "--skip-existing"],
    )

Server specific flags go into the standard `args` attribute. Credentials come from the usual rattler auth sources (keychain, auth file,
or env vars such as `PREFIX_API_KEY`). Extra flags can be passed after `--`.
""",
    attrs = {
        "packages": attr.label_list(providers = [CondaPackageInfo], mandatory = True),
        "transitive": attr.bool(default = True),
        "server": attr.string(
            mandatory = True,
            values = ["prefix", "quetz", "artifactory", "anaconda", "cloudsmith", "s3"],
        ),
        "_rattler_build": attr.label(
            default = "//tools:rattler_build",
            allow_files = True,
            executable = True,
            cfg = "target",
        ),
    },
)
