//! Running Bazel: the dry run (`cquery`) that enumerates every
//! `conda_package` target, and builds of selected targets.

use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use miette::{Context, IntoDiagnostic};
use serde::Deserialize;

/// Reads `CondaPackageInfo` (rules_rattler) of each matched target. cquery
/// only runs loading + analysis, no build actions.
const CQUERY_FORMAT: &str = r#"
def format(target):
    for key, info in providers(target).items():
        if key.endswith("%CondaPackageInfo"):
            return json.encode({
                "label": str(target.label),
                "name": info.name,
                "version": info.version,
                "build": info.build,
                "build_number": info.build_number,
                "subdir": info.subdir,
                "noarch": info.noarch,
                "license": info.license,
                "license_family": info.license_family,
                "run": info.run,
                "constrains": info.constrains,
                "siblings": [{"name": s.name, "spec": s.spec} for s in info.siblings],
                "host": [{"name": h.name, "version": h.version} for h in info.host],
                "run_exports": info.run_exports,
                "depends": info.depends,
                "package": info.package.path,
            })
    return ""
"#;

/// A `conda_package` target as seen by the dry run.
#[derive(Debug, Clone, Deserialize)]
pub struct CondaTarget {
    pub label: String,
    pub name: String,
    pub version: String,
    pub build: String,
    pub build_number: u64,
    pub subdir: String,
    pub noarch: Option<String>,
    pub license: Option<String>,
    pub license_family: Option<String>,
    /// Run requirements written by hand or derived from Python deps.
    pub run: Vec<String>,
    pub constrains: Vec<String>,
    /// Other `conda_package` targets of this workspace it depends on.
    pub siblings: Vec<Sibling>,
    /// Locked conda packages it is built against (`@conda//...`).
    pub host: Vec<HostPackage>,
    pub run_exports: Vec<String>,
    /// Final run requirements as computed by Bazel (run_exports of the
    /// locked host packages applied, siblings pinned).
    pub depends: Vec<String>,
    /// The `.conda` file, relative to the workspace (`bazel-out/...`).
    pub package: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Sibling {
    pub name: String,
    pub spec: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HostPackage {
    pub name: String,
    #[allow(dead_code)]
    pub version: String,
}

/// How to invoke Bazel for one workspace.
#[derive(Debug, Clone)]
pub struct Bazel {
    pub command: String,
    pub workspace: PathBuf,
    pub targets: String,
    pub extra_args: Vec<String>,
}

impl Bazel {
    fn command(&self, subcommand: &str, flags: &[String]) -> Command {
        let mut cmd = Command::new(&self.command);
        cmd.current_dir(&self.workspace)
            .arg(subcommand)
            .args(&self.extra_args)
            .args(flags)
            .stdin(Stdio::null())
            // stdout of this process is the JSON-RPC channel to pixi, so
            // Bazel's stdout is captured; stderr is forwarded (and its tail
            // kept for error messages).
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        cmd
    }

    fn run(&self, mut cmd: Command) -> miette::Result<String> {
        let mut child = cmd
            .spawn()
            .into_diagnostic()
            .with_context(|| format!("failed to run `{}`", self.command))?;
        let stderr = child.stderr.take().expect("stderr is piped");
        let forward = std::thread::spawn(move || {
            use std::io::BufRead;
            let mut tail = std::collections::VecDeque::new();
            for line in std::io::BufReader::new(stderr).lines().map_while(Result::ok) {
                eprintln!("{line}");
                if tail.len() == 40 {
                    tail.pop_front();
                }
                tail.push_back(line);
            }
            tail
        });
        let output = child.wait_with_output().into_diagnostic()?;
        let tail = forward.join().unwrap_or_default();
        if !output.status.success() {
            let errors: Vec<&String> = tail.iter().filter(|l| l.starts_with("ERROR")).collect();
            let shown: Vec<&String> = if errors.is_empty() { tail.iter().collect() } else { errors };
            miette::bail!(
                "`{} {}` failed ({}):\n{}",
                self.command,
                cmd.get_args().map(|a| a.to_string_lossy()).collect::<Vec<_>>().join(" "),
                output.status,
                shown.iter().map(|l| l.as_str()).collect::<Vec<_>>().join("\n")
            );
        }
        String::from_utf8(output.stdout).into_diagnostic()
    }

    /// The dry run: all `conda_package` targets matching `pattern`.
    pub fn conda_targets(&self, pattern: &str, flags: &[String]) -> miette::Result<Vec<CondaTarget>> {
        let format_file = std::env::temp_dir().join(format!(
            "pixi-build-bazel-{}.cquery",
            std::process::id()
        ));
        fs_err::write(&format_file, CQUERY_FORMAT).into_diagnostic()?;

        let mut cmd = self.command("cquery", flags);
        cmd.arg(format!("kind(\"conda_package rule\", {pattern})"))
            .arg("--output=starlark")
            .arg(format!("--starlark:file={}", format_file.display()));
        let stdout = self.run(cmd);
        let _ = fs_err::remove_file(&format_file);

        stdout?
            .lines()
            .map(str::trim)
            .filter(|l| l.starts_with('{'))
            .map(|l| {
                serde_json::from_str(l)
                    .into_diagnostic()
                    .with_context(|| format!("unexpected cquery output: {l}"))
            })
            .collect()
    }

    /// `bazel build` the given labels.
    pub fn build(&self, labels: &[String], flags: &[String]) -> miette::Result<()> {
        let mut cmd = self.command("build", flags);
        cmd.args(labels);
        self.run(cmd).map(|_| ())
    }

    pub fn resolve(&self, workspace_relative: &str) -> PathBuf {
        self.workspace.join(workspace_relative)
    }
}

/// Inputs that should trigger re-evaluation by pixi: everything in the
/// workspace except Bazel's output symlinks and environments. Bazel itself
/// decides what actually needs rebuilding.
pub fn input_globs(workspace: &Path) -> Vec<String> {
    let mut globs = Vec::new();
    let Ok(entries) = fs_err::read_dir(workspace) else {
        return vec!["**/*".to_string()];
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with("bazel-") || matches!(name.as_str(), ".pixi" | ".git" | "target") {
            continue;
        }
        if entry.path().is_dir() {
            globs.push(format!("{name}/**"));
        } else {
            globs.push(name);
        }
    }
    globs.sort();
    globs
}
