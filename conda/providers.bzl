"""Providers shared by the conda rules."""

CondaPackageInfo = provider(
    doc = "A conda package built by `conda_package`.",
    fields = {
        "name": "Package name.",
        "version": "Package version.",
        "build": "Build string.",
        "build_number": "Build number.",
        "subdir": "Conda subdir, e.g. `linux-64` or `noarch`.",
        "noarch": "`generic`, `python` or None.",
        "license": "SPDX license or None.",
        "license_family": "License family or None.",
        "run": "Run requirements written by hand or derived from Python deps (MatchSpecs).",
        "constrains": "Run constraints.",
        "siblings": "list of struct(name, spec): other conda_package targets of this workspace it depends on.",
        "host": "list of struct(name, version): locked conda packages it was built against.",
        "depends": "Final run requirements written into index.json.",
        "run_exports": "Weak run exports of this package.",
        "package": "The `.conda` File.",
        "python_dests": "depset of module paths (relative to site-packages) shipped by this package and its in-repo deps.",
        "transitive_packages": "depset of `.conda` Files: this package and every in-repo package it depends on.",
    },
)

CondaDepInfo = provider(
    doc = "A conda package from a pixi.lock, used as a Bazel dependency.",
    fields = {
        "name": "Package name.",
        "version": "Locked version.",
        "build": "Locked build string.",
        "run_exports": "list of weak + strong run exports of the package.",
    },
)
