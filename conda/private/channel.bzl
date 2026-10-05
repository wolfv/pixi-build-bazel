"""Implementation of `conda_channel`."""

load("//conda:providers.bzl", "CondaPackageInfo")

def collect_packages(targets, transitive):
    if transitive:
        return depset(transitive = [t[CondaPackageInfo].transitive_packages for t in targets]).to_list()
    return [t[CondaPackageInfo].package for t in targets]

def _conda_channel_impl(ctx):
    packages = collect_packages(ctx.attr.packages, ctx.attr.transitive)
    out = ctx.actions.declare_directory(ctx.label.name)
    args = ctx.actions.args()
    args.add("index")
    args.add("--output", out.path)
    args.add_all(packages)
    ctx.actions.run(
        executable = ctx.executable._builder,
        arguments = [args],
        inputs = packages,
        outputs = [out],
        mnemonic = "CondaIndex",
        progress_message = "Indexing conda channel %{output}",
    )
    return [DefaultInfo(files = depset([out]))]

conda_channel = rule(
    implementation = _conda_channel_impl,
    doc = """A local conda channel directory (`<subdir>/*.conda` + `repodata.json`).

Use it with `pixi` / `conda` / `mamba` via `file://$(bazel info bazel-bin)/path/to/channel`,
or put it into an OCI image layer.
""",
    attrs = {
        "packages": attr.label_list(providers = [CondaPackageInfo], mandatory = True),
        "transitive": attr.bool(default = True, doc = "Also include in-repo packages reachable via `deps`."),
        "_builder": attr.label(
            default = "//tools:conda_builder",
            allow_files = True,
            executable = True,
            cfg = "exec",
        ),
    },
)
