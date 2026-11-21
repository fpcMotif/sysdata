//! Child processes with a deadline. A cleanup tool must never be hostage to
//! a child that waits on a lock or a prompt nobody will answer.
use std::{
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc, Mutex, OnceLock},
    thread,
    time::{Duration, Instant},
};

pub const PROBE_TIMEOUT: Duration = Duration::from_secs(20);
pub const CLEAN_TIMEOUT: Duration = Duration::from_secs(600);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Output {
    /// Exit status, or the signal number negated when a signal ended it.
    pub status: i32,
    pub text: String,
    pub timed_out: bool,
}

impl Output {
    pub fn ok(&self) -> bool {
        self.status == 0 && !self.timed_out
    }
}

/// Runs `program` with stdin at `/dev/null`, collecting stdout (and stderr
/// when `merge_stderr`). Past `timeout` the child is killed and the output
/// so far is returned, without waiting for grandchildren holding the pipe.
pub fn run(
    program: &Path,
    args: &[&str],
    merge_stderr: bool,
    timeout: Duration,
) -> std::io::Result<Output> {
    let mut child = Command::new(program)
        .args(args)
        .env("PATH", search_path().join(":"))
        .env("HOMEBREW_NO_AUTO_UPDATE", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(if merge_stderr {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .spawn()?;
    let text = Arc::new(Mutex::new(Vec::new()));
    let readers: Vec<_> = [
        child
            .stdout
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
        child
            .stderr
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
    ]
    .into_iter()
    .flatten()
    .map(|mut pipe| {
        let text = Arc::clone(&text);
        thread::spawn(move || {
            let mut chunk = [0u8; 16 * 1024];
            while let Ok(n) = pipe.read(&mut chunk) {
                if n == 0 {
                    break;
                }
                text.lock().expect("output").extend_from_slice(&chunk[..n]);
            }
        })
    })
    .collect();
    let deadline = Instant::now() + timeout;
    let (status, timed_out) = loop {
        if let Some(status) = child.try_wait()? {
            break (status, false);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            break (child.wait()?, true);
        }
        thread::sleep(Duration::from_millis(15));
    };
    if !timed_out {
        for reader in readers {
            let _ = reader.join();
        }
    }
    use std::os::unix::process::ExitStatusExt;
    let status = status
        .code()
        .unwrap_or_else(|| -status.signal().unwrap_or(1));
    let text = String::from_utf8_lossy(&text.lock().expect("output")).into_owned();
    Ok(Output {
        status,
        text,
        timed_out,
    })
}

/// Runs a probe command and returns its stdout only when it succeeded.
pub fn probe(program: &Path, args: &[&str]) -> Option<String> {
    run(program, args, false, PROBE_TIMEOUT)
        .ok()
        .filter(Output::ok)
        .map(|out| out.text)
}

/// Runs `script` as root through the standard administrator prompt.
/// Dismissing the prompt makes osascript fail with `(-128)`.
pub fn run_privileged(script: &str) -> std::io::Result<Output> {
    let escaped = script.replace('\\', "\\\\").replace('"', "\\\"");
    let source = format!("do shell script \"{escaped}\" with administrator privileges");
    run(
        Path::new("/usr/bin/osascript"),
        &["-e", &source],
        true,
        CLEAN_TIMEOUT,
    )
}

pub fn was_cancelled(output: &Output) -> bool {
    output.text.contains("(-128)")
}

/// Removes osascript's "12:345: execution error: " prefix.
pub fn describe_failure(command: &str, output: &Output) -> String {
    let text = output.text.trim();
    let text = match text.find(": execution error: ") {
        Some(at) if text[..at].chars().all(|c| c.is_ascii_digit() || c == ':') => {
            &text[at + ": execution error: ".len()..]
        }
        _ => text,
    };
    if output.timed_out {
        format!(
            "{command} was still running after {} minutes, so it was stopped. Another program may hold its lock.",
            CLEAN_TIMEOUT.as_secs() / 60
        )
    } else if text.is_empty() {
        format!("{command} failed (exit {})", output.status)
    } else {
        text.to_string()
    }
}

/// `'…'` quoting for a POSIX shell.
pub fn quote(path: &Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

/// Finds a tool the way a login shell would. A GUI app inherits almost no
/// PATH, and "not looked for" must not read as "not installed".
pub fn which(name: &str) -> Option<PathBuf> {
    search_path()
        .iter()
        .map(|dir| Path::new(dir).join(name))
        .find(|candidate| is_executable(candidate))
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

pub fn search_path() -> &'static [String] {
    static PATH: OnceLock<Vec<String>> = OnceLock::new();
    PATH.get_or_init(|| {
        let home = home().display().to_string();
        let mut dirs: Vec<String> = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        .map(String::from)
        .into();
        for sub in [
            ".cargo/bin",
            ".local/bin",
            "Library/pnpm",
            ".volta/bin",
            ".asdf/shims",
            ".local/share/mise/shims",
            "Library/Application Support/fnm/aliases/default/bin",
            ".bun/bin",
            ".deno/bin",
        ] {
            dirs.push(format!("{home}/{sub}"));
        }
        if let Ok(version) = std::fs::read_to_string(format!("{home}/.nvm/alias/default")) {
            let version = version.trim();
            if !version.is_empty() {
                let version = if version.starts_with('v') {
                    version.to_string()
                } else {
                    format!("v{version}")
                };
                dirs.push(format!("{home}/.nvm/versions/node/{version}/bin"));
            }
        }
        if let Some(inherited) = std::env::var_os("PATH") {
            dirs.extend(
                inherited
                    .to_string_lossy()
                    .split(':')
                    .filter(|d| !d.is_empty())
                    .map(String::from),
            );
        }
        let mut seen = std::collections::HashSet::new();
        dirs.retain(|d| seen.insert(d.clone()));
        dirs
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_wedged_child_is_killed_at_its_deadline() {
        let started = Instant::now();
        let out = run(
            Path::new("/bin/sleep"),
            &["30"],
            true,
            Duration::from_millis(200),
        )
        .unwrap();
        assert!(out.timed_out);
        assert!(!out.ok());
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn output_and_status_are_collected() {
        let out = run(
            Path::new("/bin/sh"),
            &["-c", "echo out; echo err >&2; exit 3"],
            true,
            Duration::from_secs(5),
        )
        .unwrap();
        assert_eq!(out.status, 3);
        assert!(out.text.contains("out") && out.text.contains("err"));
        let quiet = run(
            Path::new("/bin/sh"),
            &["-c", "echo err >&2"],
            false,
            Duration::from_secs(5),
        )
        .unwrap();
        assert!(quiet.ok() && quiet.text.is_empty());
    }

    #[test]
    fn a_prompting_child_gets_eof() {
        let out = run(
            Path::new("/bin/sh"),
            &["-c", "read answer; echo got:$answer"],
            true,
            Duration::from_secs(5),
        )
        .unwrap();
        assert_eq!(out.text.trim(), "got:");
    }

    #[test]
    fn osascript_prefix_is_removed() {
        let out = Output {
            status: 1,
            text: "12:345: execution error: rm: /x: Operation not permitted (1)\n".into(),
            timed_out: false,
        };
        assert_eq!(
            describe_failure("rm", &out),
            "rm: /x: Operation not permitted (1)"
        );
        assert_eq!(quote(Path::new("/a'b")), "'/a'\\''b'");
    }
}
