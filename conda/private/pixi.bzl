"""`pixi` module extension: conda packages from a pixi.lock as Bazel deps.

For every locked platform, one repository installs the complete environment
(all packages extracted into a single prefix, text prefix placeholders
replaced), so `$ORIGIN`-relative rpaths between packages keep working. Every
package gets a `conda_locked_package` target in that repository, and a hub
repository exposes `@<name>//<package>` with a `select()` over platforms.

    pixi = use_extension("@rules_rattler//conda:extensions.bzl", "pixi")
    pixi.workspace(name = "conda", lock = "//:pixi.lock")
    use_repo(pixi, "conda")
    register_toolchains("@conda//:all")   # optional: conda Python as py toolchain
"""

load(":yaml.bzl", "parse_yaml")

# conda subdir -> (@platforms//os, @platforms//cpu)
_SUBDIR_CONSTRAINTS = {
    "linux-64": ("linux", "x86_64"),
    "linux-aarch64": ("linux", "aarch64"),
    "linux-ppc64le": ("linux", "ppc64le"),
    "osx-64": ("macos", "x86_64"),
    "osx-arm64": ("macos", "aarch64"),
    "win-64": ("windows", "x86_64"),
}

_HDR_EXTS = (".h", ".hh", ".hpp", ".hxx", ".inc", ".inl", ".ipp", ".tcc")
_BAD_LABEL_CHARS = (" ", "\"", "'", "\\", ":", "\t")

def _label_safe(path):
    for c in _BAD_LABEL_CHARS:
        if c in path:
            return False
    return not path.startswith("_pkgs/") and path not in ("BUILD", "BUILD.bazel", "WORKSPACE", "REPO.bazel")

def _split_filename(url):
    fname = url.rsplit("/", 1)[-1]
    if fname.endswith(".conda"):
        stem = fname[:-len(".conda")]
    elif fname.endswith(".tar.bz2"):
        stem = fname[:-len(".tar.bz2")]
    else:
        fail("unsupported package format: " + url)
    name, version, build = stem.rsplit("-", 2)
    return fname, stem, name, version, build

def _dep_name(spec):
    return spec.strip().split(" ")[0].split("[")[0]

# ---------------------------------------------------------------------------
# Environment repository
# ---------------------------------------------------------------------------

def _read_paths(rctx, info_dir):
    paths_json = info_dir + "/paths.json"
    if rctx.path(paths_json).exists:
        return json.decode(rctx.read(paths_json))["paths"]

    # Very old packages only have info/files.
    return [{"_path": p} for p in rctx.read(info_dir + "/files").split("\n") if p]

def _install_package(rctx, pkg, prefix):
    fname, stem, _, _, _ = _split_filename(pkg["url"])
    archive = "_pkgs/" + fname + (".zip" if fname.endswith(".conda") else "")
    if fname.endswith(".conda"):
        rctx.extract(archive, output = "_pkgs/" + stem)
        rctx.extract("_pkgs/{0}/info-{0}.tar.zst".format(stem), output = "_pkgs/" + stem)
        entries = _read_paths(rctx, "_pkgs/" + stem + "/info")

        # Metapackages have an empty payload, which Bazel refuses to extract.
        if entries:
            rctx.extract("_pkgs/{0}/pkg-{0}.tar.zst".format(stem), output = ".")
    else:
        # tar.bz2 has info/ next to the content; it is read right away and
        # the shared info/ directory is removed after all packages.
        rctx.extract(archive, output = ".")
        entries = _read_paths(rctx, "info")

    files = []
    for e in entries:
        path = e["_path"]
        if e.get("path_type") == "directory":
            continue
        placeholder = e.get("prefix_placeholder")
        if placeholder and e.get("file_mode", "text") == "text":
            content = rctx.read(path)
            rctx.file(
                path,
                content.replace(placeholder, prefix),
                executable = path.startswith("bin/") or content.startswith("#!"),
                legacy_utf8 = False,
            )
        if _label_safe(path):
            files.append(path)
    return files

def _closure(start, graph):
    seen = {start: True}
    queue = [start]
    for _ in range(len(graph) + 1):
        if not queue:
            break
        nxt = []
        for n in queue:
            for d in graph.get(n, []):
                if d not in seen:
                    seen[d] = True
                    nxt.append(d)
        queue = nxt
    return sorted(seen.keys())

def _starlark_list(items, indent = 8):
    if not items:
        return "[]"
    pad = " " * indent
    return "[\n" + "".join([pad + json.encode(i) + ",\n" for i in items]) + " " * (indent - 4) + "]"

def _install_from_lock(rctx, pkgs):
    prefix = str(rctx.path("."))

    # Download everything in parallel (deduplicated by the repository cache).
    pending = []
    for pkg in pkgs:
        fname = _split_filename(pkg["url"])[0]
        out = "_pkgs/" + fname + (".zip" if fname.endswith(".conda") else "")
        pending.append(rctx.download(pkg["url"], out, sha256 = pkg["sha256"], block = False))
    for p in pending:
        p.wait()

    files_by_pkg = {}
    for pkg in pkgs:
        files_by_pkg[pkg["name"]] = _install_package(rctx, pkg, prefix)
    rctx.delete("_pkgs")
    rctx.delete("info")
    return files_by_pkg

def _link_prefix(rctx, prefix, pkgs):
    # An environment installed by someone else (pixi, for pixi-build-bazel):
    # link it in instead of installing from the lock.
    # Not watched: the prefix belongs to pixi and may be deleted later; the
    # backend passes RULES_RATTLER_PIXI_HOST_KEY when its contents change.
    for entry in rctx.path(prefix).readdir(watch = "no"):
        if entry.basename not in ("BUILD", "BUILD.bazel", "REPO.bazel", "WORKSPACE"):
            rctx.symlink(entry, entry.basename)
    return {pkg["name"]: [f for f in pkg["files"] if _label_safe(f)] for pkg in pkgs}

def _conda_env_repo_impl(rctx):
    pkgs = json.decode(rctx.attr.packages)
    if rctx.attr.prefix:
        files_by_pkg = _link_prefix(rctx, rctx.attr.prefix, pkgs)
    else:
        files_by_pkg = _install_from_lock(rctx, pkgs)

    graph = {}
    for pkg in pkgs:
        # A package can list the same dependency twice (different constraints).
        deps = {}
        for spec in pkg["depends"]:
            d = _dep_name(spec)
            if d in files_by_pkg and d != pkg["name"]:
                deps[d] = True
        graph[pkg["name"]] = sorted(deps.keys())

    # Classify package contents.
    py = {}  # name -> (site-packages root, py srcs, other files under site-packages)
    cc = {}  # name -> (hdrs, libs)
    for name, files in files_by_pkg.items():
        py_srcs = []
        py_data = []
        root = None
        hdrs = []
        shared = []
        static = []
        for f in files:
            parts = f.split("/")
            if parts[0] == "site-packages":
                root = "site-packages"
            elif len(parts) > 3 and parts[0] == "lib" and parts[1].startswith("python") and parts[2] == "site-packages":
                root = "/".join(parts[:3])
            else:
                if parts[0] == "include" and f.endswith(_HDR_EXTS):
                    hdrs.append(f)
                elif parts[0] == "lib" and len(parts) == 2:
                    base = parts[1]
                    if ".so" in base or base.endswith(".dylib"):
                        shared.append(f)
                    elif base.endswith(".a"):
                        static.append(f)
                continue
            if f.endswith(".py"):
                py_srcs.append(f)
            else:
                py_data.append(f)
        if py_srcs:
            py[name] = (root, py_srcs, py_data)
        if hdrs or shared or static:
            cc[name] = (hdrs, shared or static)

    out = [
        'load("@rules_cc//cc:cc_import.bzl", "cc_import")',
        'load("@rules_cc//cc:cc_library.bzl", "cc_library")',
        'load("@rules_python//python:py_library.bzl", "py_library")',
        'load("@rules_python//python:py_runtime.bzl", "py_runtime")',
        'load("@rules_python//python:py_runtime_pair.bzl", "py_runtime_pair")',
        'load("@rules_python//python/cc:py_cc_toolchain.bzl", "py_cc_toolchain")',
        'load("@rules_rattler//conda/private:locked.bzl", "conda_locked_package")',
        "",
        'package(default_visibility = ["//visibility:public"])',
        "",
    ]
    for pkg in pkgs:
        name = pkg["name"]
        deps = graph[name]
        closure = _closure(name, graph)
        out.append("# ---- {} {} {}".format(name, pkg["version"], pkg["build"]))
        out.append('filegroup(\n    name = "{}__files",\n    srcs = {},\n)'.format(name, _starlark_list(files_by_pkg[name])))

        # Everything needed at runtime: own files plus all transitive deps.
        out.append('filegroup(\n    name = "{}__closure",\n    srcs = {},\n)'.format(
            name,
            _starlark_list([":{}__files".format(n) for n in closure]),
        ))
        py_attr = "None"
        cc_attr = "[]"
        if name in py:
            root, srcs, _ = py[name]
            out.append("""py_library(
    name = "{name}__py",
    srcs = {srcs},
    data = [":{name}__closure"],
    imports = ["{root}"],
    deps = {deps},
)""".format(
                name = name,
                srcs = _starlark_list(srcs),
                root = root,
                deps = _starlark_list([":{}__py".format(d) for d in deps if d in py]),
            ))
            py_attr = '":{}__py"'.format(name)
        if name in cc:
            hdrs, libs = cc[name]

            # Prebuilt libraries go through cc_import: cc_shared_library
            # ignores prebuilt .so files listed in a cc_library's srcs. Every
            # name (libz.so, libz.so.1, ...) is imported so the one matching
            # the SONAME is present in Bazel's _solib tree at runtime.
            imports = []
            for i, lib in enumerate(libs):
                kind = "static_library" if lib.endswith(".a") else "shared_library"
                imports.append(":{}__lib{}".format(name, i))
                out.append('cc_import(\n    name = "{}__lib{}",\n    {} = "{}",\n)'.format(name, i, kind, lib))
            out.append("""cc_library(
    name = "{name}__cc",
    hdrs = {hdrs},
    includes = ["include"],
    data = [":{name}__closure"],
    deps = {deps},
)""".format(
                name = name,
                hdrs = _starlark_list(hdrs),
                deps = _starlark_list(imports + [":{}__cc".format(d) for d in deps if d in cc]),
            ))
            cc_attr = '[":{}__cc"]'.format(name)
        out.append("""conda_locked_package(
    name = "{name}",
    package_name = "{name}",
    version = "{version}",
    build = "{build}",
    run_exports = {run_exports},
    files = [":{name}__files"],
    py = {py},
    deps = {cc},
)
""".format(
            name = name,
            version = pkg["version"],
            build = pkg["build"],
            run_exports = json.encode(pkg["run_exports"]),
            py = py_attr,
            cc = cc_attr,
        ))

    # The conda Python as a rules_python toolchain.
    python = [p for p in pkgs if p["name"] == "python"]
    if python:
        major_minor = ".".join(python[0]["version"].split(".")[:2])
        interpreter = "bin/python" + major_minor
        if not rctx.path(interpreter).exists:
            interpreter = "python.exe"
        out.append("""py_runtime(
    name = "python_runtime",
    files = [":python__closure"],
    interpreter = "{interpreter}",
    interpreter_version_info = {{"major": "{major}", "minor": "{minor}"}},
    python_version = "PY3",
)

py_runtime_pair(
    name = "python_runtime_pair",
    py3_runtime = ":python_runtime",
)

# Python.h & co. for C extensions (pybind11_bazel uses current_py_cc_headers).
cc_library(
    name = "python_headers",
    hdrs = {headers},
    includes = ["include/python{major_minor}"],
)

py_cc_toolchain(
    name = "python_cc_toolchain",
    headers = ":python_headers",
    python_version = "{major_minor}",
)
""".format(
            headers = _starlark_list([f for f in files_by_pkg["python"] if f.startswith("include/python" + major_minor + "/")]),
            major_minor = major_minor,
            interpreter = interpreter,
            major = major_minor.split(".")[0],
            minor = major_minor.split(".")[1],
        ))

    rctx.file("BUILD.bazel", "\n".join(out))

_conda_env_repo = repository_rule(
    implementation = _conda_env_repo_impl,
    attrs = {
        "packages": attr.string(mandatory = True, doc = "JSON list of locked packages."),
        "subdir": attr.string(mandatory = True),
        "prefix": attr.string(doc = "Use this installed environment instead of installing `packages` from the lock."),
    },
)

# ---------------------------------------------------------------------------
# Hub repository
# ---------------------------------------------------------------------------

def _conda_hub_repo_impl(rctx):
    envs = json.decode(rctx.attr.envs)
    out = ['package(default_visibility = ["//visibility:public"])', ""]
    all_names = {}
    for subdir, env in envs.items():
        os, cpu = _SUBDIR_CONSTRAINTS[subdir]
        out.append('config_setting(\n    name = "{}",\n    constraint_values = ["@platforms//os:{}", "@platforms//cpu:{}"],\n)'.format(subdir, os, cpu))
        for n in env["packages"]:
            all_names.setdefault(n, []).append(subdir)
        if env["python"]:
            out.append("""toolchain(
    name = "python_toolchain_{sd}",
    target_compatible_with = ["@platforms//os:{os}", "@platforms//cpu:{cpu}"],
    toolchain = "@{repo}//:python_runtime_pair",
    toolchain_type = "@rules_python//python:toolchain_type",
)

toolchain(
    name = "python_cc_toolchain_{sd}",
    target_compatible_with = ["@platforms//os:{os}", "@platforms//cpu:{cpu}"],
    toolchain = "@{repo}//:python_cc_toolchain",
    toolchain_type = "@rules_python//python/cc:toolchain_type",
)""".format(sd = subdir.replace("-", "_"), os = os, cpu = cpu, repo = env["repo"]))
    out.append("")
    for name in sorted(all_names):
        branches = "".join([
            '        ":{}": "@{}//:{}",\n'.format(sd, envs[sd]["repo"], name)
            for sd in all_names[name]
        ])
        out.append('alias(\n    name = "{}",\n    actual = select({{\n{}    }}),\n)'.format(name, branches))
    rctx.file("BUILD.bazel", "\n".join(out) + "\n")

    # `@conda//numpy` as shorthand for `@conda//:numpy`.
    for name in all_names:
        rctx.file(name + "/BUILD.bazel", 'alias(\n    name = "{0}",\n    actual = "//:{0}",\n    visibility = ["//visibility:public"],\n)\n'.format(name))

_conda_hub_repo = repository_rule(
    implementation = _conda_hub_repo_impl,
    attrs = {"envs": attr.string(mandatory = True)},
)

# ---------------------------------------------------------------------------
# Extension
# ---------------------------------------------------------------------------

def _run_exports(record):
    exports = record.get("run_exports") or {}
    return list(exports.get("weak") or []) + list(exports.get("strong") or [])

def _prefix_packages(mctx, prefix):
    """Package records of an installed environment (from conda-meta/*.json)."""
    pkgs = []
    meta = mctx.path(prefix + "/conda-meta")
    if not meta.exists:
        fail("{} is not a conda environment (no conda-meta/)".format(prefix))
    for f in meta.readdir(watch = "no"):
        if not f.basename.endswith(".json"):
            continue
        rec = json.decode(mctx.read(f, watch = "no"))
        pkgs.append({
            "name": rec["name"],
            "version": rec["version"],
            "build": rec["build"],
            "depends": rec.get("depends") or [],
            # pixi applies run_exports itself when it drives the build.
            "run_exports": [],
            "files": rec.get("files") or [],
        })
    return sorted(pkgs, key = lambda p: p["name"])

def _pixi_impl(mctx):
    # Set by pixi-build-bazel for `conda/build_v1`: build against the host
    # environment pixi solved and installed, not the one from the lock.
    host_prefix = mctx.getenv("RULES_RATTLER_PIXI_HOST_PREFIX", "")
    host_subdir = mctx.getenv("RULES_RATTLER_PIXI_HOST_PLATFORM", "")

    # Changes whenever the packages in the prefix change (reads of the prefix
    # itself are not watched).
    mctx.getenv("RULES_RATTLER_PIXI_HOST_KEY", "")
    for mod in mctx.modules:
        for tag in mod.tags.workspace:
            if host_prefix:
                pkgs = _prefix_packages(mctx, host_prefix)
                repo = "{}_{}".format(tag.name, host_subdir.replace("-", "_"))
                _conda_env_repo(name = repo, packages = json.encode(pkgs), subdir = host_subdir, prefix = host_prefix)
                _conda_hub_repo(name = tag.name, envs = json.encode({host_subdir: {
                    "repo": repo,
                    "packages": [p["name"] for p in pkgs],
                    "python": any([p["name"] == "python" for p in pkgs]),
                }}))
                continue

            lock = parse_yaml(mctx.read(tag.lock))
            if str(lock.get("version")) not in ("6", "7"):
                fail("{}: unsupported pixi.lock version {}".format(tag.lock, lock.get("version")))
            environments = lock.get("environments") or {}
            if tag.environment not in environments:
                fail("{}: no environment {!r} (have: {})".format(tag.lock, tag.environment, ", ".join(environments)))
            env = environments[tag.environment]

            records = {}
            for rec in lock.get("packages") or []:
                if "conda" in rec:
                    records[rec["conda"]] = rec

            hub = {}
            for subdir, entries in (env.get("packages") or {}).items():
                if tag.platforms and subdir not in tag.platforms:
                    continue
                if subdir not in _SUBDIR_CONSTRAINTS:
                    continue
                pkgs = []
                for entry in entries:
                    if "conda" not in entry:
                        # TODO: PyPI packages from the lock.
                        continue
                    url = entry["conda"]
                    rec = records[url]
                    _, _, name, version, build = _split_filename(url)
                    pkgs.append({
                        "url": url,
                        "sha256": rec["sha256"],
                        "name": name,
                        "version": version,
                        "build": build,
                        "depends": rec.get("depends") or [],
                        "run_exports": _run_exports(rec),
                    })
                repo = "{}_{}".format(tag.name, subdir.replace("-", "_"))
                _conda_env_repo(name = repo, packages = json.encode(pkgs), subdir = subdir)
                hub[subdir] = {
                    "repo": repo,
                    "packages": [p["name"] for p in pkgs],
                    "python": any([p["name"] == "python" for p in pkgs]),
                }
            _conda_hub_repo(name = tag.name, envs = json.encode(hub))
    return mctx.extension_metadata(reproducible = not host_prefix)

_workspace = tag_class(attrs = {
    "name": attr.string(default = "conda", doc = "Name of the hub repository."),
    "lock": attr.label(mandatory = True, doc = "The pixi.lock file."),
    "environment": attr.string(default = "default"),
    "platforms": attr.string_list(doc = "Limit to these conda subdirs (default: all locked ones)."),
})

pixi = module_extension(
    implementation = _pixi_impl,
    tag_classes = {"workspace": _workspace},
)
