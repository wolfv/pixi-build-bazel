//! Hermetic helper used by the Bazel `conda_package` / `conda_channel` rules.
//!
//! * `build`: turns a JSON manifest (written by Starlark) into a reproducible
//!   `.conda` archive.
//! * `index`: lays out a set of `.conda` files as a channel directory and
//!   writes `repodata.json` for every subdir.

use std::{
    collections::BTreeMap,
    fs,
    io::BufWriter,
    path::{Path, PathBuf},
};

mod relink;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use rattler_conda_types::{
    compression_level::CompressionLevel,
    package::{
        AboutJson, IndexJson, PackageFile, PathType, PathsEntry, PathsJson, RunExportsJson,
    },
    PackageRecord,
};
use rattler_digest::{compute_bytes_digest, compute_file_digest, Md5, Sha256};
use serde::Deserialize;
use serde_json::{json, Map, Value};

#[derive(Parser)]
#[command(about = "Build conda packages and channels for Bazel")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Build a `.conda` package from a manifest.
    Build {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        output: PathBuf,
        /// zstd compression level (1-22).
        #[arg(long, default_value_t = 19)]
        compression_level: i32,
    },
    /// Create a channel directory (with repodata.json) from packages.
    Index {
        #[arg(long)]
        output: PathBuf,
        packages: Vec<PathBuf>,
    },
}

#[derive(Deserialize)]
struct Manifest {
    name: String,
    version: String,
    build: String,
    build_number: u64,
    subdir: String,
    #[serde(default)]
    noarch: Option<String>,
    #[serde(default)]
    depends: Vec<String>,
    #[serde(default)]
    constrains: Vec<String>,
    #[serde(default)]
    track_features: Vec<String>,
    #[serde(default)]
    license: Option<String>,
    #[serde(default)]
    license_family: Option<String>,
    #[serde(default)]
    summary: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    homepage: Option<String>,
    #[serde(default)]
    repository: Option<String>,
    #[serde(default)]
    documentation: Option<String>,
    #[serde(default)]
    run_exports: Option<RunExportsJson>,
    /// Milliseconds since the epoch; fixed for reproducibility. Zip can't
    /// represent dates before 1980, so the default is 2023-01-01.
    #[serde(default = "default_timestamp")]
    timestamp: i64,
    #[serde(default)]
    files: Vec<FileEntry>,
    #[serde(default)]
    symlinks: Vec<SymlinkEntry>,
}

fn default_timestamp() -> i64 {
    1_672_531_200_000
}

#[derive(Deserialize)]
struct FileEntry {
    src: PathBuf,
    dest: String,
    #[serde(default)]
    executable: bool,
}

#[derive(Deserialize)]
struct SymlinkEntry {
    dest: String,
    target: String,
}

fn main() -> Result<()> {
    match Cli::parse().command {
        Command::Build {
            manifest,
            output,
            compression_level,
        } => build(&manifest, &output, compression_level),
        Command::Index { output, packages } => index(&output, &packages),
    }
}

/// Reject absolute paths and `..` so a manifest can't escape the package root.
fn check_dest(dest: &str) -> Result<()> {
    let p = Path::new(dest);
    if p.is_absolute()
        || p.components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
    {
        bail!("invalid destination path in package: {dest:?}");
    }
    if p.starts_with("info") {
        bail!("{dest:?}: the info/ directory is reserved for package metadata");
    }
    Ok(())
}

fn build(manifest_path: &Path, output: &Path, compression_level: i32) -> Result<()> {
    let manifest: Manifest = serde_json::from_slice(
        &fs::read(manifest_path).with_context(|| format!("reading {manifest_path:?}"))?,
    )
    .context("parsing manifest")?;

    let staging = tempfile::tempdir()?;
    let root = staging.path();
    let mut paths_entries = Vec::new();
    let mut seen = BTreeMap::new();

    for f in &manifest.files {
        check_dest(&f.dest)?;
        if let Some(prev) = seen.insert(f.dest.clone(), f.src.clone()) {
            bail!(
                "two files map to {:?}: {:?} and {:?}",
                f.dest,
                prev,
                f.src
            );
        }
        let target = root.join(&f.dest);
        fs::create_dir_all(target.parent().unwrap())?;
        // Copy (not link): Bazel inputs are read-only and may be symlinks.
        fs::copy(&f.src, &target).with_context(|| format!("copying {:?}", f.src))?;
        set_mode(&target, f.executable)?;
        relink::fix_elf_runpath(&target, &f.dest)
            .with_context(|| format!("rewriting RUNPATH of {}", f.dest))?;
        let bytes = fs::read(&target)?;
        paths_entries.push(PathsEntry {
            relative_path: PathBuf::from(&f.dest),
            no_link: false,
            path_type: PathType::HardLink,
            prefix_placeholder: None,
            sha256: Some(compute_bytes_digest::<Sha256>(&bytes)),
            size_in_bytes: Some(bytes.len() as u64),
        });
    }

    for s in &manifest.symlinks {
        check_dest(&s.dest)?;
        if seen.insert(s.dest.clone(), PathBuf::from(&s.target)).is_some() {
            bail!("duplicate path in package: {:?}", s.dest);
        }
        let link = root.join(&s.dest);
        fs::create_dir_all(link.parent().unwrap())?;
        make_symlink(&s.target, &link)?;
        paths_entries.push(PathsEntry {
            relative_path: PathBuf::from(&s.dest),
            no_link: false,
            path_type: PathType::SoftLink,
            prefix_placeholder: None,
            sha256: None,
            size_in_bytes: None,
        });
    }

    paths_entries.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));

    let info = root.join("info");
    fs::create_dir_all(&info)?;

    // index.json: built as JSON and validated by round-tripping through the
    // rattler type, so we never emit something conda can't read.
    let mut index = Map::new();
    index.insert("name".into(), json!(manifest.name));
    index.insert("version".into(), json!(manifest.version));
    index.insert("build".into(), json!(manifest.build));
    index.insert("build_number".into(), json!(manifest.build_number));
    index.insert("subdir".into(), json!(manifest.subdir));
    index.insert("depends".into(), json!(manifest.depends));
    index.insert("constrains".into(), json!(manifest.constrains));
    if !manifest.track_features.is_empty() {
        index.insert(
            "track_features".into(),
            json!(manifest.track_features.join(" ")),
        );
    }
    if let Some(noarch) = &manifest.noarch {
        index.insert("noarch".into(), json!(noarch));
    } else if let Some((platform, arch)) = platform_arch(&manifest.subdir) {
        index.insert("platform".into(), json!(platform));
        index.insert("arch".into(), json!(arch));
    }
    if let Some(l) = &manifest.license {
        index.insert("license".into(), json!(l));
    }
    if let Some(l) = &manifest.license_family {
        index.insert("license_family".into(), json!(l));
    }
    index.insert(
        "timestamp".into(),
        json!(manifest.timestamp),
    );
    let index_str = serde_json::to_string_pretty(&Value::Object(index))?;
    IndexJson::from_str(&index_str).context("generated index.json is invalid")?;
    fs::write(info.join("index.json"), index_str)?;

    let mut about = Map::new();
    let opt = |v: &Option<String>| v.as_ref().map(|s| json!(s));
    if let Some(v) = opt(&manifest.summary) {
        about.insert("summary".into(), v);
    }
    if let Some(v) = opt(&manifest.description) {
        about.insert("description".into(), v);
    }
    if let Some(v) = opt(&manifest.license) {
        about.insert("license".into(), v);
    }
    if let Some(v) = &manifest.homepage {
        about.insert("home".into(), json!([v]));
    }
    if let Some(v) = &manifest.repository {
        about.insert("dev_url".into(), json!([v]));
    }
    if let Some(v) = &manifest.documentation {
        about.insert("doc_url".into(), json!([v]));
    }
    let about_str = serde_json::to_string_pretty(&Value::Object(about))?;
    AboutJson::from_str(&about_str).context("generated about.json is invalid")?;
    fs::write(info.join("about.json"), about_str)?;

    let paths_json = PathsJson {
        paths: paths_entries.clone(),
        paths_version: 1,
    };
    fs::write(
        info.join("paths.json"),
        serde_json::to_string_pretty(&paths_json)?,
    )?;

    // Legacy `info/files` is still read by some tools.
    let files_list: String = paths_entries
        .iter()
        .map(|e| format!("{}\n", e.relative_path.to_string_lossy()))
        .collect();
    fs::write(info.join("files"), files_list)?;

    if let Some(run_exports) = &manifest.run_exports {
        if !run_exports.is_empty() {
            fs::write(
                info.join("run_exports.json"),
                serde_json::to_string_pretty(run_exports)?,
            )?;
        }
    }

    let mut all_paths = walk(root)?;
    all_paths.sort();

    let out_name = output
        .file_name()
        .and_then(|n| n.to_str())
        .and_then(|n| n.strip_suffix(".conda"))
        .context("output must end in .conda")?
        .to_string();
    let expected = format!("{}-{}-{}", manifest.name, manifest.version, manifest.build);
    if out_name != expected {
        bail!("output name {out_name:?} does not match package identity {expected:?}");
    }

    let timestamp = jiff::Timestamp::from_millisecond(manifest.timestamp)?;
    let file = fs::File::create(output)?;
    rattler_package_streaming::write::write_conda_package(
        BufWriter::new(file),
        root,
        &all_paths,
        CompressionLevel::Numeric(compression_level),
        Some(1), // single-threaded zstd => byte-identical output
        &out_name,
        Some(&timestamp),
        None,
    )?;
    Ok(())
}

fn platform_arch(subdir: &str) -> Option<(&'static str, &'static str)> {
    Some(match subdir {
        "linux-64" => ("linux", "x86_64"),
        "linux-aarch64" => ("linux", "aarch64"),
        "linux-ppc64le" => ("linux", "ppc64le"),
        "osx-64" => ("osx", "x86_64"),
        "osx-arm64" => ("osx", "arm64"),
        "win-64" => ("win", "x86_64"),
        "win-arm64" => ("win", "arm64"),
        _ => return None,
    })
}

/// All files and symlinks under `root` (absolute paths), not following links.
fn walk(root: &Path) -> Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(&dir)? {
            let entry = entry?;
            let ft = entry.file_type()?;
            if ft.is_dir() {
                stack.push(entry.path());
            } else {
                out.push(entry.path());
            }
        }
    }
    Ok(out)
}

#[cfg(unix)]
fn set_mode(path: &Path, executable: bool) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mode = if executable { 0o755 } else { 0o644 };
    fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_mode(path: &Path, _executable: bool) -> Result<()> {
    let mut perms = fs::metadata(path)?.permissions();
    perms.set_readonly(false);
    fs::set_permissions(path, perms)?;
    Ok(())
}

#[cfg(unix)]
fn make_symlink(target: &str, link: &Path) -> Result<()> {
    std::os::unix::fs::symlink(target, link)?;
    Ok(())
}

#[cfg(not(unix))]
fn make_symlink(target: &str, link: &Path) -> Result<()> {
    std::os::windows::fs::symlink_file(target, link)?;
    Ok(())
}

fn index(output: &Path, packages: &[PathBuf]) -> Result<()> {
    let mut subdirs: BTreeMap<String, Map<String, Value>> = BTreeMap::new();
    // conda clients always fetch noarch, so it must exist.
    subdirs.entry("noarch".into()).or_default();

    for pkg in packages {
        let file_name = pkg
            .file_name()
            .and_then(|n| n.to_str())
            .context("invalid package file name")?
            .to_string();
        if !file_name.ends_with(".conda") {
            bail!("{file_name}: only .conda packages are supported");
        }
        let index_json: IndexJson = rattler_package_streaming::seek::read_package_file(pkg)
            .with_context(|| format!("reading index.json from {pkg:?}"))?;
        let size = fs::metadata(pkg)?.len();
        let sha256 = compute_file_digest::<Sha256>(pkg)?;
        let md5 = compute_file_digest::<Md5>(pkg)?;
        let record = PackageRecord::from_index_json(index_json, Some(size), Some(sha256), Some(md5))?;
        let subdir = record.subdir.clone();

        let dir = output.join(&subdir);
        fs::create_dir_all(&dir)?;
        fs::copy(pkg, dir.join(&file_name))?;

        let packages = subdirs.entry(subdir).or_default();
        if packages
            .insert(file_name.clone(), serde_json::to_value(&record)?)
            .is_some()
        {
            bail!("{file_name} was given twice");
        }
    }

    for (subdir, packages) in subdirs {
        let dir = output.join(&subdir);
        fs::create_dir_all(&dir)?;
        let repodata = json!({
            "info": { "subdir": subdir },
            "packages": {},
            "packages.conda": packages,
            "removed": [],
            "repodata_version": 1,
        });
        fs::write(
            dir.join("repodata.json"),
            serde_json::to_string_pretty(&repodata)?,
        )?;
    }
    Ok(())
}
