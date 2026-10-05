//! The pixi build protocol: `conda/outputs` reports every `conda_package`
//! target of the workspace, `conda/build_v1` builds the one pixi selected.

use std::{
    collections::{BTreeMap, hash_map::DefaultHasher},
    hash::{Hash, Hasher},
    path::PathBuf,
    str::FromStr,
};

use miette::{Context, IntoDiagnostic};
use pixi_build_types::{
    BinaryPackageSpec, NamedSpec, PackageSpec, PathSpec, SourcePackageLocationSpec,
    SourcePackageName, SourcePackageSpec,
    procedures::{
        conda_build_v1::{CondaBuildV1Params, CondaBuildV1Result},
        conda_outputs::{
            CondaOutput, CondaOutputDependencies, CondaOutputIgnoreRunExports,
            CondaOutputMetadata, CondaOutputRunExports, CondaOutputsParams, CondaOutputsResult,
        },
    },
};
use rattler_conda_types::{
    MatchSpec, NoArchType, PackageName, ParseStrictness, Platform, VersionWithSource,
};
use serde::Deserialize;
use tokio::sync::Mutex;

use crate::bazel::{Bazel, CondaTarget, input_globs};

/// `[package.build.config]` of the pixi manifest.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub struct Config {
    /// Bazel executable (default: `$BAZEL`, then the bundled `bazelisk`,
    /// then `bazel` on PATH).
    pub bazel: Option<String>,
    /// Target pattern searched for `conda_package` targets (default `//...`).
    pub targets: Option<String>,
    /// Extra flags for every Bazel command.
    #[serde(default)]
    pub bazel_args: Vec<String>,
    /// Bazel workspace directory relative to the manifest (default: the
    /// manifest's directory).
    pub workspace: Option<PathBuf>,
    /// Label of the rules_rattler module (for `--platforms` when cross-building).
    pub rules_rattler: Option<String>,
    /// Who provides the environment packages are compiled against.
    #[serde(default)]
    pub host_environment: HostEnvironment,
}

/// Where the `@conda//...` dependencies used during the build come from.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum HostEnvironment {
    /// The workspace's pixi.lock, read by Bazel (`pixi.workspace(lock = ...)`),
    /// exactly as in a standalone `bazel build`. Outputs report no host or
    /// build dependencies, so pixi solves and installs nothing for them; run
    /// requirements already contain the lock's run_exports.
    #[default]
    Lock,
    /// pixi solves and installs a host environment per output from the
    /// `@conda` packages each target links against (and applies their
    /// run_exports); Bazel builds against that environment.
    Pixi,
}

pub struct BazelBackend {
    bazel: Bazel,
    rules_rattler: String,
    host_environment: HostEnvironment,
    /// The dry-run result, keyed by host platform.
    targets: Mutex<BTreeMap<Platform, Vec<CondaTarget>>>,
}

impl BazelBackend {
    pub fn new(workspace: PathBuf, config: Config) -> Self {
        let command = config
            .bazel
            .or_else(|| std::env::var("BAZEL").ok())
            .or_else(bundled_bazelisk)
            .unwrap_or_else(|| "bazel".to_string());
        Self {
            bazel: Bazel {
                command,
                workspace: config.workspace.map_or(workspace.clone(), |w| workspace.join(w)),
                targets: config.targets.unwrap_or_else(|| "//...".to_string()),
                extra_args: config.bazel_args,
            },
            rules_rattler: config.rules_rattler.unwrap_or_else(|| "@rules_rattler".to_string()),
            host_environment: config.host_environment,
            targets: Mutex::new(BTreeMap::new()),
        }
    }

    /// `--platforms` for the requested host platform (only when it differs
    /// from the machine we run on).
    fn platform_flags(&self, host: Platform, build: Platform) -> Vec<String> {
        if host == build || host == Platform::NoArch {
            return vec![];
        }
        vec![format!("--platforms={}//conda/platforms:{}", self.rules_rattler, host)]
    }

    async fn dry_run(&self, host: Platform, build: Platform) -> miette::Result<Vec<CondaTarget>> {
        let mut cache = self.targets.lock().await;
        if let Some(targets) = cache.get(&host) {
            return Ok(targets.clone());
        }
        let targets = self
            .bazel
            .conda_targets(&self.bazel.targets, &self.platform_flags(host, build))?;
        cache.insert(host, targets.clone());
        Ok(targets)
    }

    pub async fn conda_outputs(&self, params: CondaOutputsParams) -> miette::Result<CondaOutputsResult> {
        let targets = self.dry_run(params.host_platform, params.build_platform).await?;
        let outputs = targets
            .iter()
            .map(|t| to_output(t, self.host_environment))
            .collect::<miette::Result<Vec<_>>>()?;
        Ok(CondaOutputsResult {
            outputs,
            input_globs: input_globs(&self.bazel.workspace),
            input_glob_sets: None,
        })
    }

    pub async fn conda_build_v1(&self, params: CondaBuildV1Params) -> miette::Result<CondaBuildV1Result> {
        let host_platform = params
            .host_prefix
            .as_ref()
            .map_or(params.output.subdir, |p| p.platform);
        let build_platform = params
            .build_prefix
            .as_ref()
            .map_or(Platform::current(), |p| p.platform);
        let targets = self.dry_run(host_platform, build_platform).await?;
        let target = targets
            .iter()
            .find(|t| t.name == params.output.name.as_normalized())
            .ok_or_else(|| {
                miette::miette!(
                    "no conda_package target produces `{}`",
                    params.output.name.as_normalized()
                )
            })?
            .clone();

        // What pixi decided: build string, and run requirements with the
        // run_exports of the host environment applied.
        let depends: Vec<String> = params
            .run_dependencies
            .iter()
            .flatten()
            .map(|d| d.spec.to_string())
            .collect();
        let constrains: Vec<String> = params
            .run_constraints
            .iter()
            .flatten()
            .map(|d| d.spec.to_string())
            .collect();
        let build = params.output.build.clone().unwrap_or(target.build.clone());
        let overrides = serde_json::json!({
            target.name.clone(): {"build": build, "depends": depends, "constrains": constrains}
        });
        let overrides = serde_json::to_string_pretty(&overrides).into_diagnostic()?;

        // A content-addressed file name: Bazel re-evaluates the module
        // extension when the env var value changes.
        fs_err::create_dir_all(&params.work_directory).into_diagnostic()?;
        let overrides_file = params
            .work_directory
            .join(format!("rules_rattler_overrides-{:016x}.json", hash(&overrides)));
        fs_err::write(&overrides_file, &overrides).into_diagnostic()?;

        let mut flags = self.platform_flags(host_platform, build_platform);
        flags.push(format!(
            "--repo_env=RULES_RATTLER_PIXI_OVERRIDES={}",
            overrides_file.display()
        ));
        if let Some(host) = params
            .host_prefix
            .as_ref()
            .filter(|_| self.host_environment == HostEnvironment::Pixi)
        {
            // Build against the environment pixi installed; the key changes
            // whenever its contents do.
            let records: Vec<String> = host
                .packages
                .iter()
                .map(|p| p.repodata_record.url.to_string())
                .collect();
            flags.push(format!(
                "--repo_env=RULES_RATTLER_PIXI_HOST_PREFIX={}",
                host.prefix.display()
            ));
            flags.push(format!("--repo_env=RULES_RATTLER_PIXI_HOST_PLATFORM={}", host.platform));
            flags.push(format!("--repo_env=RULES_RATTLER_PIXI_HOST_KEY={:016x}", hash(&records)));
        }

        self.bazel.build(&[target.label.clone()], &flags)?;

        // Same flags as the build, so this reuses its analysis.
        let built = self
            .bazel
            .conda_targets(&target.label, &flags)?
            .into_iter()
            .next()
            .ok_or_else(|| miette::miette!("{} vanished after building", target.label))?;
        let package = self.bazel.resolve(&built.package);

        let output_dir = params.output_directory.unwrap_or(params.work_directory);
        fs_err::create_dir_all(&output_dir).into_diagnostic()?;
        let output_file = output_dir.join(package.file_name().expect("package has a file name"));
        // Bazel outputs are read-only; copy rather than link.
        if output_file.exists() {
            fs_err::remove_file(&output_file).into_diagnostic()?;
        }
        fs_err::copy(&package, &output_file)
            .into_diagnostic()
            .with_context(|| format!("copying {}", package.display()))?;

        Ok(CondaBuildV1Result {
            output_file,
            input_globs: input_globs(&self.bazel.workspace),
            input_glob_sets: None,
            name: built.name,
            version: VersionWithSource::from_str(&built.version).into_diagnostic()?,
            build: built.build,
            subdir: built.subdir.parse().into_diagnostic()?,
        })
    }
}

/// The `bazelisk` installed next to this backend (a run dependency of the
/// conda package), so users don't need Bazel on PATH. bazelisk still honors
/// the workspace's `.bazelversion`.
fn bundled_bazelisk() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    ["bazelisk", "bazelisk.exe"]
        .iter()
        .map(|name| dir.join(name))
        .find(|p| p.is_file())
        .map(|p| p.to_string_lossy().into_owned())
}

fn hash<T: Hash>(value: &T) -> u64 {
    let mut h = DefaultHasher::new();
    value.hash(&mut h);
    h.finish()
}

fn source_name(name: &str) -> miette::Result<SourcePackageName> {
    Ok(SourcePackageName::from(PackageName::from_str(name).into_diagnostic()?))
}

/// A MatchSpec string as a binary dependency.
fn binary_spec(spec: &str) -> miette::Result<NamedSpec<PackageSpec>> {
    let parsed = MatchSpec::from_str(spec, ParseStrictness::Lenient)
        .into_diagnostic()
        .with_context(|| format!("parsing `{spec}`"))?;
    let name = parsed
        .name
        .as_exact()
        .ok_or_else(|| miette::miette!("`{spec}` has no package name"))?
        .as_normalized()
        .to_string();
    Ok(NamedSpec {
        name: source_name(&name)?,
        spec: PackageSpec::Binary(Box::new(BinaryPackageSpec {
            version: parsed.version.clone(),
            build: parsed.build.clone(),
            ..BinaryPackageSpec::default()
        })),
    })
}

/// Another output of this workspace: built from the same source (`.`).
fn sibling_spec(name: &str, spec: &str) -> miette::Result<NamedSpec<PackageSpec>> {
    let parsed = MatchSpec::from_str(spec, ParseStrictness::Lenient).into_diagnostic()?;
    Ok(NamedSpec {
        name: source_name(name)?,
        spec: PackageSpec::Source(SourcePackageSpec {
            location: SourcePackageLocationSpec::Path(PathSpec { path: ".".into() }),
            version: parsed.version.clone(),
            build: None,
            build_number: None,
            extras: None,
            flags: None,
            subdir: None,
            license: None,
            condition: None,
        }),
    })
}

fn to_output(target: &CondaTarget, host_environment: HostEnvironment) -> miette::Result<CondaOutput> {
    let noarch = match target.noarch.as_deref() {
        Some("generic") => NoArchType::generic(),
        Some("python") => NoArchType::python(),
        _ => NoArchType::none(),
    };

    let sibling_specs: Vec<&str> = target.siblings.iter().map(|s| s.spec.as_str()).collect();
    let (run_specs, host): (&[String], Vec<NamedSpec<PackageSpec>>) = match host_environment {
        // Bazel resolved everything from its lock: report the final run
        // requirements and no host environment at all.
        HostEnvironment::Lock => (&target.depends, vec![]),
        // Packages the target links against become host dependencies; pixi
        // solves them and applies their run_exports to the run requirements.
        HostEnvironment::Pixi => (
            &target.run,
            target
                .host
                .iter()
                .map(|h| {
                    Ok(NamedSpec {
                        name: source_name(&h.name)?,
                        spec: PackageSpec::Binary(Box::default()),
                    })
                })
                .collect::<miette::Result<Vec<_>>>()?,
        ),
    };

    let mut run = run_specs
        .iter()
        .filter(|s| !sibling_specs.contains(&s.as_str()))
        .map(|s| binary_spec(s))
        .collect::<miette::Result<Vec<_>>>()?;
    for s in &target.siblings {
        run.push(sibling_spec(&s.name, &s.spec)?);
    }

    let constraints = target
        .constrains
        .iter()
        .map(|s| {
            let named = binary_spec(s)?;
            let PackageSpec::Binary(binary) = named.spec else {
                unreachable!()
            };
            Ok(NamedSpec {
                name: named.name,
                spec: pixi_build_types::ConstraintSpec::Binary(*binary),
            })
        })
        .collect::<miette::Result<Vec<_>>>()?;

    Ok(CondaOutput {
        metadata: CondaOutputMetadata {
            name: PackageName::from_str(&target.name).into_diagnostic()?,
            version: VersionWithSource::from_str(&target.version).into_diagnostic()?,
            build: target.build.clone(),
            build_number: target.build_number,
            subdir: target.subdir.parse().into_diagnostic()?,
            license: target.license.clone(),
            license_family: target.license_family.clone(),
            flags: vec![],
            noarch,
            purls: None,
            python_site_packages_path: None,
            variant: BTreeMap::new(),
        },
        build_dependencies: Some(CondaOutputDependencies::default()),
        host_dependencies: Some(CondaOutputDependencies {
            depends: host,
            constraints: vec![],
        }),
        run_dependencies: CondaOutputDependencies {
            depends: run,
            constraints,
        },
        extra_dependencies: BTreeMap::new(),
        ignore_run_exports: CondaOutputIgnoreRunExports::default(),
        run_exports: CondaOutputRunExports {
            weak: target
                .run_exports
                .iter()
                .map(|s| binary_spec(s))
                .collect::<miette::Result<Vec<_>>>()?,
            ..CondaOutputRunExports::default()
        },
        input_globs: None,
        input_glob_sets: None,
    })
}
