"""`conda_python_files`: turn Bazel Python targets into site-packages content.

Walks the transitive `PyInfo` sources of `deps` and sorts every file by the
Bazel repository that owns it:

* repositories listed in `bundle` (default: the main repo) are copied into
  `site-packages/`, laid out by their import roots;
* rules_python pip repositories (`pip_hub`) become conda run requirements;
* any other repository must be mapped in `repo_map`, either to a conda
  MatchSpec, to `"bundle"`, or to `""` (ignore).

Files already provided by `exclude_packages` (other `conda_package` targets)
are skipped, which is how one Bazel graph is split into several packages.
"""

load("@rules_python//python:py_info.bzl", "PyInfo")
load("//conda:providers.bzl", "CondaDepInfo", "CondaPackageInfo")

CondaPythonFilesInfo = provider(
    doc = "Python files mapped into a noarch: python conda package.",
    fields = {
        "files": "list of (File, dest) tuples, dest starts with `site-packages/`.",
        "depends": "list of conda MatchSpecs derived from external repositories.",
        "host": "list of (name, version, run_exports) of packages built against (the locked python for extensions).",
    },
)

def _runfiles_path(f, workspace_name):
    if f.short_path.startswith("../"):
        return f.short_path[3:]
    return workspace_name + "/" + f.short_path

_PipDepsInfo = provider(
    doc = "External packages that first-party targets depend on directly.",
    fields = {
        "labels": "depset of pip target labels",
        "conda": "depset of conda package names (from pixi.lock deps)",
    },
)

def _is_pip(label):
    # rules_python pip repos: `rules_python++pip+<hub>` and `..._<hub>_311_<pkg>`.
    return "+pip+" in label.repo_name

def _pip_deps_aspect_impl(target, ctx):
    direct = []
    transitive = []
    conda = []
    conda_transitive = []
    for dep in getattr(ctx.rule.attr, "deps", []):
        if type(dep) != "Target":
            continue
        if CondaDepInfo in dep:
            conda.append(dep[CondaDepInfo].name)
        elif _is_pip(dep.label):
            direct.append(dep.label)
        elif _PipDepsInfo in dep:
            transitive.append(dep[_PipDepsInfo].labels)
            conda_transitive.append(dep[_PipDepsInfo].conda)
    return [_PipDepsInfo(
        labels = depset(direct, transitive = transitive),
        conda = depset(conda, transitive = conda_transitive),
    )]

# Only records edges from non-pip code into pip; the pip packages' own
# dependency closure is left to the conda solver.
_pip_deps_aspect = aspect(
    implementation = _pip_deps_aspect_impl,
    attr_aspects = ["deps"],
)

def _pip_name(label, hub):
    """PyPI name for a pip target: `@hub//numpy` or `@hub_311_numpy//:pkg`."""
    repo = label.repo_name
    if repo.endswith("+" + hub) and label.package:
        return label.package.replace("_", "-").lower()
    rest = repo.split(hub, 1)[1].lstrip("_")
    head, _, tail = rest.partition("_")
    if head.isdigit():
        rest = tail
    return rest.replace("_", "-").lower()

def _import_path(f, workspace_name, roots):
    """Module path of `f` relative to its innermost import root."""
    rpath = _runfiles_path(f, workspace_name)
    repo_root = rpath.split("/")[0]
    rel = rpath[len(repo_root) + 1:]
    for root in roots:
        if rpath.startswith(root + "/"):
            rel = rpath[len(root) + 1:]
            break
    if "/_virtual_imports/" in "/" + rel:
        rel = rel.split("_virtual_imports/", 1)[1].split("/", 1)[1]
    return rel

def _conda_python_files_impl(ctx):
    workspace_name = ctx.workspace_name
    bundle = {r: True for r in ctx.attr.bundle}

    excluded = {}  # module paths (relative to site-packages)
    for pkg in ctx.attr.exclude_packages:
        for d in pkg[CondaPackageInfo].python_dests.to_list():
            excluded[d] = True

    imports = depset(transitive = [d[PyInfo].imports for d in ctx.attr.deps]).to_list()

    # Longest import root first, so `_main/intrinsic_sdk` beats `_main`.
    roots = sorted(imports, key = lambda r: -len(r))

    sources = depset(transitive = [d[PyInfo].transitive_sources for d in ctx.attr.deps]).to_list()
    source_set = {f: True for f in sources}

    # Non-.py runfiles: extension modules (`*.so`), package data, ...
    data = [
        f
        for f in depset(transitive = [d[DefaultInfo].default_runfiles.files for d in ctx.attr.deps]).to_list()
        if f not in source_set and not f.short_path.startswith("_solib_") and "/_solib_" not in f.short_path
    ]

    python = ctx.attr.python[CondaDepInfo] if ctx.attr.python else None
    if python:
        major_minor = ".".join(python.version.split(".")[:2])
        site_packages = "lib/python{}/site-packages/".format(major_minor)
    else:
        site_packages = "site-packages/"

    files = []
    depends = {}
    unmapped = {}
    for f in sources + data:
        is_source = f in source_set
        repo = f.owner.repo_name if f.owner else ""
        module = repo.split("+")[0]
        if repo and ("+pip+" in repo or "+pixi+" in repo):
            continue  # handled via _pip_deps_aspect below

        rel = _import_path(f, workspace_name, roots)
        dest = site_packages + rel

        # Already shipped by an in-repo conda dependency (which is pinned
        # through `deps` already).
        if rel in excluded:
            continue

        if repo == "" or repo in bundle or module in bundle:
            action = "bundle"
        elif module in ctx.attr.repo_map:
            action = ctx.attr.repo_map[module]
        elif is_source:
            unmapped.setdefault(module, []).append(rel)
            continue
        else:
            continue  # data from an unmapped repository (e.g. toolchains)

        if action == "bundle":
            files.append((f, dest))
        elif action != "":
            depends[action] = True

    # Python-level use of a locked conda package: depend on it by name, the
    # way conda-forge Python packages do.
    for d in ctx.attr.deps:
        if CondaDepInfo in d:
            depends[d[CondaDepInfo].name] = True
    for name in depset(transitive = [d[_PipDepsInfo].conda for d in ctx.attr.deps]).to_list():
        depends[name] = True

    # Compiled for a specific Python: pin it like rattler-build does, plus
    # python's run_exports (python_abi).
    host = []
    if python:
        major, minor = major_minor.split(".")
        depends["python >={}.{},<{}.{}.0a0".format(major, minor, major, int(minor) + 1)] = True

        # python's run_exports (python_abi) are applied like any host dep.
        host.append((python.name, python.version, tuple(python.run_exports)))

    pip_labels = depset(transitive = [d[_PipDepsInfo].labels for d in ctx.attr.deps]).to_list()
    pip_labels += [d.label for d in ctx.attr.deps if _is_pip(d.label)]
    for label in pip_labels:
        if not ctx.attr.pip_hub:
            fail("{}: depends on pip package {}; set `pip_hub`".format(ctx.label, label))
        name = _pip_name(label, ctx.attr.pip_hub)
        spec = ctx.attr.pypi_to_conda.get(name, name)
        if spec:
            depends[spec] = True

    if unmapped:
        fail("{}: Python files come from repositories without a mapping. Add them to `repo_map` ".format(ctx.label) +
             "(a conda MatchSpec, \"bundle\", or \"\" to ignore):\n" +
             "\n".join([
                 "  {}: {} files, e.g.\n{}".format(k, len(v), "\n".join(["    " + p for p in sorted(v)[:5]]))
                 for k, v in sorted(unmapped.items())
             ]))

    # Two repos can legitimately contribute the same module path (e.g.
    # rules_python generated `__init__.py`); keep the first.
    seen = {}
    unique = []
    for f, dest in files:
        if dest not in seen:
            seen[dest] = True
            unique.append((f, dest))

    return [
        DefaultInfo(files = depset([f for f, _ in unique])),
        CondaPythonFilesInfo(files = unique, depends = sorted(depends.keys()), host = host),
    ]

conda_python_files = rule(
    implementation = _conda_python_files_impl,
    attrs = {
        "deps": attr.label_list(providers = [PyInfo], mandatory = True, aspects = [_pip_deps_aspect]),
        "bundle": attr.string_list(doc = "Extra repositories (module names) whose files are copied into the package."),
        "repo_map": attr.string_dict(doc = "Module name -> conda MatchSpec, `bundle`, or `\"\"` to ignore."),
        "pip_hub": attr.string(doc = "rules_python pip hub name; its packages become run requirements."),
        "pypi_to_conda": attr.string_dict(doc = "Normalized PyPI name -> conda MatchSpec (`\"\"` drops it)."),
        "exclude_packages": attr.label_list(providers = [CondaPackageInfo], doc = "Skip files these packages already contain."),
        "python": attr.label(providers = [CondaDepInfo], doc = "Locked python the extensions are built for (`@conda//python`). Makes the package platform specific."),
    },
)
