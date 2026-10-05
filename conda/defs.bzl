"""Public API for building conda packages with Bazel."""

load("//conda:providers.bzl", _CondaPackageInfo = "CondaPackageInfo")
load("//conda/private:channel.bzl", _conda_channel = "conda_channel")
load("//conda/private:package.bzl", _conda_package = "conda_package")
load("//conda/private:python.bzl", _conda_python_files = "conda_python_files")
load("//conda/private:upload.bzl", _conda_upload = "conda_upload")

CondaPackageInfo = _CondaPackageInfo
conda_package = _conda_package
conda_channel = _conda_channel
conda_upload = _conda_upload
conda_python_files = _conda_python_files

def conda_python_package(
        name,
        py_deps,
        deps = [],
        bundle = [],
        repo_map = {},
        pip_hub = "",
        pypi_to_conda = {},
        python = None,
        **kwargs):
    """A `noarch: python` package built from Bazel Python targets.

    Python sources owned by the main repository (plus `bundle`) are placed in
    `site-packages/`; pip dependencies and mapped external repositories turn
    into run requirements. Files already shipped by the in-repo conda `deps`
    are left out, so a Bazel graph can be split into several packages.

    Args:
        name: target and (default) package name.
        py_deps: py_library / py_proto_library / ... targets to package.
        deps: other `conda_package` targets this package depends on.
        bundle: extra Bazel repositories (module names) to bundle.
        repo_map: module name -> conda MatchSpec, "bundle", or "" (ignore).
        pip_hub: rules_python pip hub name.
        pypi_to_conda: PyPI name -> conda MatchSpec overrides.
        python: a locked python (`@conda//python`) for packages containing
            extension modules; files then go to `lib/pythonX.Y/site-packages`
            and python / python_abi are pinned. Without it the package is
            `noarch: python`.
        **kwargs: forwarded to `conda_package`.
    """
    _conda_python_files(
        name = name + "_py_files",
        deps = py_deps,
        bundle = bundle,
        repo_map = repo_map,
        pip_hub = pip_hub,
        pypi_to_conda = pypi_to_conda,
        exclude_packages = deps,
        python = python,
        visibility = ["//visibility:private"],
    )
    _conda_package(
        name = name,
        srcs = [name + "_py_files"] + kwargs.pop("srcs", []),
        deps = deps,
        depends = ([] if python else ["python >=3.10"]) + kwargs.pop("depends", []),
        noarch = "" if python else "python",
        **kwargs
    )
