//! Make Bazel-linked ELF files relocatable inside a conda prefix.
//!
//! Bazel links against shared libraries through `_solib_<cpu>` symlink trees
//! and runfiles directories, and bakes those into DT_RUNPATH / DT_RPATH. In a
//! conda environment the libraries live in `$PREFIX/lib`, so we replace the
//! Bazel entries with `$ORIGIN/<relative path to lib>`. The new value is
//! written in place (it is shorter than what Bazel produces); if it wouldn't
//! fit we fail instead of producing a broken binary.

use std::{fs, path::Path};

use anyhow::{bail, Result};
use goblin::elf::{dynamic::DT_RPATH, dynamic::DT_RUNPATH, Elf};

fn is_bazel_entry(entry: &str) -> bool {
    entry.contains("_solib_") || entry.contains(".runfiles/") || entry.contains("/bazel-out/")
}

/// `$ORIGIN`-relative path from `dest`'s directory to `lib/`.
fn origin_to_lib(dest: &str) -> String {
    let depth = Path::new(dest).parent().map_or(0, |p| p.components().count());
    if dest.starts_with("lib/") && depth == 1 {
        return "$ORIGIN".to_string();
    }
    format!("$ORIGIN/{}lib", "../".repeat(depth))
}

pub fn fix_elf_runpath(path: &Path, dest: &str) -> Result<()> {
    let mut bytes = fs::read(path)?;
    if bytes.len() < 4 || &bytes[..4] != b"\x7fELF" {
        return Ok(());
    }
    let elf = Elf::parse(&bytes)?;
    let Some(dynamic) = &elf.dynamic else {
        return Ok(()); // static binary
    };

    // goblin already maps DT_STRTAB to a file offset.
    let strtab_off = dynamic.info.strtab as u64;
    if strtab_off == 0 {
        return Ok(());
    }

    let mut patches = Vec::new();
    for d in &dynamic.dyns {
        if d.d_tag != DT_RUNPATH && d.d_tag != DT_RPATH {
            continue;
        }
        let start = (strtab_off + d.d_val) as usize;
        let len = bytes[start..].iter().position(|&b| b == 0).unwrap_or(0);
        let old = String::from_utf8_lossy(&bytes[start..start + len]).to_string();
        if !old.split(':').any(is_bazel_entry) {
            continue;
        }

        let mut entries = vec![origin_to_lib(dest)];
        for e in old.split(':') {
            if !e.is_empty() && !is_bazel_entry(e) && !entries.iter().any(|x| x == e) {
                entries.push(e.to_string());
            }
        }
        let new = entries.join(":");
        if new.len() > len {
            bail!("new RUNPATH {new:?} is longer than the original {old:?}");
        }
        patches.push((start, len, new));
    }

    if patches.is_empty() {
        return Ok(());
    }
    for (start, len, new) in patches {
        bytes[start..start + len].fill(0);
        bytes[start..start + new.len()].copy_from_slice(new.as_bytes());
    }
    let perms = fs::metadata(path)?.permissions();
    fs::write(path, bytes)?;
    fs::set_permissions(path, perms)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::origin_to_lib;

    #[test]
    fn relative_lib() {
        assert_eq!(origin_to_lib("bin/tool"), "$ORIGIN/../lib");
        assert_eq!(origin_to_lib("lib/libfoo.so"), "$ORIGIN");
        assert_eq!(
            origin_to_lib("lib/python3.12/site-packages/pkg/_ext.so"),
            "$ORIGIN/../../../../lib"
        );
    }
}
