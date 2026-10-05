"""Implementation of `conda_package`."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_pkg//pkg:providers.bzl", "PackageFilegroupInfo", "PackageFilesInfo", "PackageSymlinkInfo")
load("@rules_rattler_pixi_context//:overrides.bzl", "PIXI_OVERRIDES")
load("//conda:providers.bzl", "CondaDepInfo", "CondaPackageInfo")
load(":python.bzl", "CondaPythonFilesInfo")
load(":subdir.bzl", "SUBDIR_ATTRS", "target_subdir")

# Pin styles for in-repo `deps`.
_PINS = ["exact", "version", "compatible", "name"]

# Fixed archive timestamp (2023-01-01) for reproducible packages.
_TIMESTAMP_MS = 1672531200000

_CondaHostDepsInfo = provider(
    doc = "Locked conda packages (`@conda//...`) that targets link against.",
    fields = {"packages": "depset of (name, version, run_exports tuple)"},
)

def _host_entry(info):
    return (info.name, info.version, tuple(info.run_exports))

def _conda_host_deps_aspect_impl(target, ctx):
    # Python packages report their own (name-only) requirements.
    if CondaPythonFilesInfo in target:
        return [_CondaHostDepsInfo(packages = depset())]
    direct = []
    transitive = []
    for attr_name in _HOST_DEP_ATTRS:
        for dep in getattr(ctx.rule.attr, attr_name, []):
            if type(dep) != "Target":
                continue
            if CondaDepInfo in dep:
                direct.append(_host_entry(dep[CondaDepInfo]))
            elif _CondaHostDepsInfo in dep:
                transitive.append(dep[_CondaHostDepsInfo].packages)
    return [_CondaHostDepsInfo(packages = depset(direct, transitive = transitive))]

# `srcs` too: rules_pkg mappings (pkg_files) reach binaries through it.
_HOST_DEP_ATTRS = ["deps", "implementation_deps", "dynamic_deps", "srcs"]

_conda_host_deps_aspect = aspect(
    implementation = _conda_host_deps_aspect_impl,
    attr_aspects = _HOST_DEP_ATTRS,
)

def _applied_run_exports(name, version, run_exports):
    # Like a host dependency in rattler-build: use the package's run_exports,
    # falling back to a lower bound on the version.
    return list(run_exports) or ["{} >={}".format(name, version)]

def _hex32(n):
    n = n & 0xffffffff
    digits = "0123456789abcdef"
    out = ""
    for _ in range(8):
        out = digits[n % 16] + out
        n = n // 16
    return out

def _pin_spec(info, pin):
    if pin == "exact":
        return "{} =={} {}".format(info.name, info.version, info.build)
    if pin == "version":
        return "{} =={}".format(info.name, info.version)
    if pin == "compatible":
        parts = info.version.split(".")
        upper = str(int(parts[0]) + 1) if parts[0].isdigit() else None
        if upper == None:
            fail("cannot compute a compatible pin for {} {}".format(info.name, info.version))
        return "{} >={},<{}".format(info.name, info.version, upper)
    return info.name

def _is_mode_executable(mode):
    # rules_pkg modes are octal strings like "0755".
    return mode != None and int(mode[-3], 8) & 1 == 1

def _join(prefix, path):
    prefix = prefix.strip("/")
    return prefix + "/" + path if prefix else path

def _collect_contents(ctx, subdir):
    files = []  # (File, dest, executable)
    symlinks = []  # (dest, target)
    depends = []  # derived from srcs (e.g. Python pip deps)
    host = []  # (name, version, run_exports) of packages built against
    python_dests = []

    def add_pkg_files(info):
        mode = info.attributes.get("mode")
        for dest, f in info.dest_src_map.items():
            if f.is_directory:
                fail("{}: directories (TreeArtifacts) are not supported yet: {}".format(ctx.label, f.short_path))
            files.append((f, dest, _is_mode_executable(mode)))

    for src in ctx.attr.srcs:
        if CondaPythonFilesInfo in src:
            info = src[CondaPythonFilesInfo]
            for f, dest in info.files:
                files.append((f, dest, False))

                # Keyed by module path, so noarch and platform packages match.
                python_dests.append(dest.split("site-packages/", 1)[1])
            depends.extend(info.depends)
            host.extend(info.host)
        elif PackageFilesInfo in src:
            add_pkg_files(src[PackageFilesInfo])
        elif PackageFilegroupInfo in src:
            fg = src[PackageFilegroupInfo]
            for info, _ in fg.pkg_files:
                add_pkg_files(info)
            for info, _ in fg.pkg_symlinks:
                symlinks.append((info.destination, info.target))
        elif PackageSymlinkInfo in src:
            info = src[PackageSymlinkInfo]
            symlinks.append((info.destination, info.target))
        else:
            exe = src[DefaultInfo].files_to_run.executable
            for f in src[DefaultInfo].files.to_list():
                files.append((f, _join(ctx.attr.prefix, f.basename), f == exe))

    bin_dir = "Library/bin" if subdir.startswith("win") else "bin"
    for b in ctx.attr.bins:
        exe = b[DefaultInfo].files_to_run.executable
        if exe == None:
            fail("{}: {} is not executable".format(ctx.label, b.label))
        files.append((exe, bin_dir + "/" + exe.basename, True))

    for dest, target in ctx.attr.symlinks.items():
        symlinks.append((dest, target))

    return files, symlinks, depends, host, python_dests

def _about(ctx):
    return {
        k: v
        for k, v in {
            "summary": ctx.attr.summary,
            "description": ctx.attr.description,
            "license": ctx.attr.license,
            "license_family": ctx.attr.license_family,
            "homepage": ctx.attr.homepage,
            "repository": ctx.attr.repository,
            "documentation": ctx.attr.documentation,
        }.items()
        if v
    }

def _sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def _package_with_recipe(ctx, meta, files, symlinks, out):
    """Creates the package with a released rattler-build: a generated recipe
    whose build script copies the staged files into $PREFIX."""
    build_script = ['cp -a "$SRC_DIR/files/." "$PREFIX/"']
    if meta.subdir.startswith("linux"):
        # Bazel's rpaths point into its own output tree (`_solib_*`,
        # runfiles); drop them so rattler-build's relinker sets a clean
        # `$ORIGIN/../lib` (it uses patchelf, which is on PATH).
        build_script.append(
            "find \"$PREFIX\" -type f -exec sh -c 'for f; do " +
            "if patchelf --print-rpath \"$f\" >/dev/null 2>&1; then patchelf --remove-rpath \"$f\"; fi; " +
            "done' _ {} +",
        )
    build = {"number": ctx.attr.build_number, "string": meta.build, "script": build_script}
    if meta.noarch:
        build["noarch"] = meta.noarch
    else:
        build["dynamic_linking"] = {"rpaths": ["lib/"]}
    requirements = {"run": meta.depends, "run_constraints": meta.constrains}
    if ctx.attr.run_exports:
        requirements["run_exports"] = {"weak": ctx.attr.run_exports}

    # JSON is valid YAML, so this is a regular rattler-build recipe.
    recipe = ctx.actions.declare_file(ctx.label.name + ".recipe.yaml")
    ctx.actions.write(recipe, json.encode_indent({
        "package": {"name": meta.name, "version": meta.version},
        "source": [{"path": "stage"}],
        "build": build,
        "requirements": requirements,
        "about": _about(ctx),
    }))

    # Stage the files next to the recipe and run rattler-build in a temp dir.
    lines = [
        "set -euo pipefail",
        'work="$(mktemp -d "${TMPDIR:-/tmp}/conda_package.XXXXXX")"',
        "trap 'rm -rf \"$work\"' EXIT",
        'files="$work/stage/files"',
    ]
    dirs = {}
    for _, dest, _ in files:
        dirs[dest.rpartition("/")[0]] = True
    for dest, _ in symlinks:
        dirs[dest.rpartition("/")[0]] = True
    for d in sorted(dirs):
        lines.append('mkdir -p "$files"/' + _sh_quote(d))
    for f, dest, executable in files:
        lines.append('cp -L {} "$files"/{} && chmod {} "$files"/{}'.format(
            _sh_quote(f.path),
            _sh_quote(dest),
            "755" if executable else "644",
            _sh_quote(dest),
        ))
    for dest, target in symlinks:
        lines.append('ln -s {} "$files"/{}'.format(_sh_quote(target), _sh_quote(dest)))
    rattler_build = ctx.executable._rattler_build
    patchelf = ctx.file._patchelf
    target = [] if meta.noarch else ["--target-platform", meta.subdir]
    lines += [
        'cp {} "$work/recipe.yaml"'.format(_sh_quote(recipe.path)),
        'export PATH="$PWD/{}:$PATH"'.format(patchelf.dirname),
        'if ! {} build --recipe "$work/recipe.yaml" --output-dir "$work/out" --test skip --no-include-recipe --log-style plain {} > "$work/log" 2>&1; then'.format(
            _sh_quote(rattler_build.path),
            " ".join(target),
        ),
        '  cat "$work/log" >&2',
        "  exit 1",
        "fi",
        'cp "$work/out/{}/{}" {}'.format(meta.subdir, out.basename, _sh_quote(out.path)),
    ]
    ctx.actions.run_shell(
        command = "\n".join(lines),
        inputs = [recipe] + [f for f, _, _ in files],
        tools = [rattler_build, patchelf],
        outputs = [out],
        mnemonic = "CondaPackage",
        progress_message = "Building conda package %{output}",
    )
    return recipe

def _package_create(ctx, meta, files, symlinks, out):
    """Creates the package with `rattler-build package create` (unreleased)."""
    manifest = ctx.actions.declare_file(ctx.label.name + ".conda_manifest.json")
    about = _about(ctx)
    ctx.actions.write(manifest, json.encode_indent(struct(
        name = meta.name,
        version = meta.version,
        build_string = meta.build,
        build_number = ctx.attr.build_number,
        target_platform = meta.subdir,
        noarch = meta.noarch,
        depends = meta.depends,
        constrains = meta.constrains,
        track_features = ctx.attr.track_features,
        license = about.get("license"),
        license_family = about.get("license_family"),
        summary = about.get("summary"),
        description = about.get("description"),
        homepage = about.get("homepage"),
        repository = about.get("repository"),
        documentation = about.get("documentation"),
        run_exports = {"weak": ctx.attr.run_exports} if ctx.attr.run_exports else None,
        files = [struct(src = f.path, dest = d, executable = x) for f, d, x in files],
        symlinks = [struct(dest = d, target = t) for d, t in symlinks],
        timestamp = _TIMESTAMP_MS,
        compression_level = ctx.attr.compression_level,
        # Bazel links through `_solib_*` trees and runfiles; those rpaths are
        # replaced with `$ORIGIN/../lib` & co.
        strip_rpath_patterns = ["_solib_", ".runfiles/"],
    )))
    ctx.actions.run(
        executable = ctx.executable._rattler_build,
        arguments = ["-q", "package", "create", "--manifest", manifest.path, "--output-dir", out.dirname],
        inputs = [manifest] + [f for f, _, _ in files],
        outputs = [out],
        mnemonic = "CondaPackage",
        progress_message = "Building conda package %{output}",
        env = {"RATTLER_BUILD_LOG_STYLE": "plain"},
    )
    return manifest

def _dedupe(items):
    out = []
    for i in items:
        if i not in out:
            out.append(i)
    return out

def _conda_package_impl(ctx):
    name = ctx.attr.package_name or ctx.label.name
    if name != name.lower():
        fail("{}: conda package names must be lowercase: {}".format(ctx.label, name))
    noarch = ctx.attr.noarch or None
    subdir = "noarch" if noarch else (ctx.attr.subdir or target_subdir(ctx))

    files, symlinks, derived_run, host, python_dests = _collect_contents(ctx, subdir)

    # Packages this was built against: explicit `host_deps` plus every locked
    # conda package that `bins` / `srcs` link against.
    host.extend([_host_entry(h[CondaDepInfo]) for h in ctx.attr.host_deps])
    for t in ctx.attr.srcs + ctx.attr.bins:
        if _CondaHostDepsInfo in t:
            host.extend(t[_CondaHostDepsInfo].packages.to_list())
    host = _dedupe(host)

    # Other packages from this Bazel workspace.
    siblings = [
        struct(name = d[CondaPackageInfo].name, spec = _pin_spec(d[CondaPackageInfo], ctx.attr.pin))
        for d in ctx.attr.deps
    ]

    # Run requirements written by hand or derived from Python deps; these are
    # reported to pixi as they are.
    run = _dedupe(list(ctx.attr.depends) + derived_run)

    depends = list(run)
    for n, v, re in host:
        depends.extend(_applied_run_exports(n, v, re))
    depends = _dedupe(depends + [s.spec for s in siblings])
    constrains = list(ctx.attr.constrains)

    # Like rattler-build, the build string hash covers what varies between
    # builds of the same version (target subdir and resolved dependencies).
    hash_input = json.encode(struct(
        subdir = subdir,
        noarch = noarch,
        depends = sorted(depends),
        constrains = sorted(constrains),
        track_features = ctx.attr.track_features,
    ))
    build = ctx.attr.build_string or "h{}_{}".format(_hex32(hash(hash_input)), ctx.attr.build_number)

    # When driven by pixi (pixi-build-bazel), pixi has solved the environments
    # and applied run_exports itself: use its final metadata.
    override = PIXI_OVERRIDES.get(name)
    if override:
        build = override.get("build") or build
        depends = override.get("depends", depends)
        constrains = override.get("constrains", constrains)

    meta = struct(
        name = name,
        version = ctx.attr.version,
        build = build,
        subdir = subdir,
        noarch = noarch,
        depends = depends,
        constrains = constrains,
    )
    out = ctx.actions.declare_file("{}-{}-{}.conda".format(name, ctx.attr.version, build))
    if ctx.attr._packager[BuildSettingInfo].value == "package-create":
        manifest = _package_create(ctx, meta, files, symlinks, out)
    else:
        manifest = _package_with_recipe(ctx, meta, files, symlinks, out)

    return [
        DefaultInfo(files = depset([out])),
        CondaPackageInfo(
            name = name,
            version = ctx.attr.version,
            build = build,
            build_number = ctx.attr.build_number,
            subdir = subdir,
            noarch = noarch,
            license = ctx.attr.license or None,
            license_family = ctx.attr.license_family or None,
            run = run,
            constrains = constrains,
            siblings = siblings,
            host = [struct(name = n, version = v) for n, v, _ in host],
            depends = depends,
            run_exports = ctx.attr.run_exports,
            package = out,
            python_dests = depset(
                python_dests,
                transitive = [d[CondaPackageInfo].python_dests for d in ctx.attr.deps],
            ),
            transitive_packages = depset(
                [out],
                transitive = [d[CondaPackageInfo].transitive_packages for d in ctx.attr.deps],
            ),
        ),
        OutputGroupInfo(manifest = depset([manifest])),
    ]

conda_package = rule(
    implementation = _conda_package_impl,
    doc = """Builds a `.conda` package from Bazel targets.

Files come from `srcs` (plain targets, or rules_pkg `pkg_files` /
`pkg_filegroup` / `pkg_mklink` for full control over paths and modes),
`bins` (installed into `bin/`, or `Library/bin/` on Windows) and `symlinks`.

Dependencies on other conda packages can be expressed either as MatchSpec
strings (`depends`) or as labels of other `conda_package` targets (`deps`),
which are pinned according to `pin`.

The subdir (`linux-64`, `osx-arm64`, ...) is derived from the Bazel target
platform, so `--platforms=...` cross builds produce correctly tagged packages.
""",
    attrs = dict(SUBDIR_ATTRS, **{
        "package_name": attr.string(doc = "Conda package name. Defaults to the target name."),
        "version": attr.string(mandatory = True),
        "build_number": attr.int(default = 0),
        "build_string": attr.string(doc = "Override the build string (default: `h<hash>_<build_number>`)."),
        "noarch": attr.string(values = ["", "generic", "python"], doc = "`generic` for platform independent packages, `python` for pure Python packages (files under `site-packages/`)."),
        "subdir": attr.string(doc = "Override the conda subdir instead of deriving it from the target platform."),
        "srcs": attr.label_list(allow_files = True, aspects = [_conda_host_deps_aspect], doc = "Files to include. Plain files land in `prefix`."),
        "prefix": attr.string(doc = "Directory (relative to the environment root) for plain `srcs`."),
        "bins": attr.label_list(aspects = [_conda_host_deps_aspect], doc = "Executable targets installed into the environment's bin directory. Locked conda packages they link against add run requirements (via run_exports)."),
        "symlinks": attr.string_dict(doc = "Symlinks to create: `{path_in_package: link_target}`."),
        "depends": attr.string_list(doc = "Run requirements as MatchSpecs, e.g. `\"libzlib >=1.3\"`."),
        "deps": attr.label_list(providers = [CondaPackageInfo], doc = "Other `conda_package` targets this package depends on at runtime."),
        "pin": attr.string(default = "version", values = _PINS, doc = "How `deps` are pinned: `exact` (version + build), `version`, `compatible` (`>=v,<major+1`) or `name`."),
        "host_deps": attr.label_list(providers = [CondaDepInfo], doc = "Locked conda packages (`@conda//...`) this was built against; their run_exports become run requirements, like rattler-build host requirements."),
        "constrains": attr.string_list(doc = "Run constraints (`run_constrained`)."),
        "run_exports": attr.string_list(doc = "Weak run exports applied to packages that build against this one."),
        "track_features": attr.string_list(),
        "license": attr.string(doc = "SPDX license expression."),
        "license_family": attr.string(),
        "summary": attr.string(),
        "description": attr.string(),
        "homepage": attr.string(),
        "repository": attr.string(),
        "documentation": attr.string(),
        "compression_level": attr.int(default = 15, doc = "zstd level (1-22)."),
        "_rattler_build": attr.label(
            default = "//tools:rattler_build",
            allow_files = True,
            executable = True,
            cfg = "exec",
        ),
        "_patchelf": attr.label(
            default = "@rattler_build//:patchelf",
            allow_single_file = True,
            cfg = "exec",
        ),
        "_packager": attr.label(default = "//conda:packager"),
    }),
    provides = [CondaPackageInfo],
)
