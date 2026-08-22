use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chrono::{DateTime, Datelike, Duration as ChronoDuration, Utc};

use crate::config::LogRotation;

use super::FileLogOptions;

const CLEANUP_INTERVAL_SECS: i64 = 60;

/// File appender with size rotation and local retention cleanup.
pub(crate) struct BoundedFileAppender {
    options: FileLogOptions,
    dir: PathBuf,
    base_name: String,
    current_path: PathBuf,
    current_size: u64,
    last_cleanup: DateTime<Utc>,
    file: Option<File>,
    now: Box<dyn Fn() -> DateTime<Utc> + Send + Sync>,
}

impl BoundedFileAppender {
    pub(crate) fn new(options: FileLogOptions) -> io::Result<Self> {
        Self::with_now(options, Box::new(Utc::now))
    }

    fn with_now(
        options: FileLogOptions,
        now: Box<dyn Fn() -> DateTime<Utc> + Send + Sync>,
    ) -> io::Result<Self> {
        let path = Path::new(&options.path);
        let dir = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf();
        let base_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("tupoproxy")
            .to_string();

        let start = now();
        let current_path = active_path_for(&dir, &base_name, options.rotation, &start);
        let (file, current_size) = open_append_file(&current_path)?;
        let mut appender = Self {
            options,
            dir,
            base_name,
            current_path,
            current_size,
            last_cleanup: start,
            file: Some(file),
            now,
        };
        appender.cleanup(&start);
        Ok(appender)
    }

    fn now(&self) -> DateTime<Utc> {
        (self.now)()
    }

    fn refresh_active_path(&mut self, now: &DateTime<Utc>) -> io::Result<bool> {
        let next_path = active_path_for(&self.dir, &self.base_name, self.options.rotation, now);
        if next_path == self.current_path {
            return Ok(false);
        }

        self.close_current()?;
        self.current_path = next_path;
        self.open_current()?;
        Ok(true)
    }

    fn rotate_for_size(&mut self, now: &DateTime<Utc>) -> io::Result<()> {
        self.close_current()?;
        if self.current_path.exists() {
            let archive_path = self.archive_path(now);
            fs::rename(&self.current_path, archive_path)?;
        }
        self.open_current()
    }

    fn archive_path(&self, now: &DateTime<Utc>) -> PathBuf {
        let file_name = self
            .current_path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(&self.base_name);
        let stamp = now.format("%Y%m%d%H%M%S");
        for seq in 0..1000 {
            let candidate = self.dir.join(format!("{file_name}.{stamp}.{seq}"));
            if !candidate.exists() {
                return candidate;
            }
        }
        self.dir.join(format!("{file_name}.{stamp}.overflow"))
    }

    fn open_current(&mut self) -> io::Result<()> {
        let (file, current_size) = open_append_file(&self.current_path)?;
        self.file = Some(file);
        self.current_size = current_size;
        Ok(())
    }

    fn close_current(&mut self) -> io::Result<()> {
        if let Some(mut file) = self.file.take() {
            file.flush()?;
        }
        Ok(())
    }

    fn should_rotate_for_size(&self, incoming_len: usize) -> bool {
        self.options.max_size_bytes > 0
            && self.current_size > 0
            && self.current_size.saturating_add(incoming_len as u64) > self.options.max_size_bytes
    }

    fn cleanup_due(&self, now: &DateTime<Utc>) -> bool {
        self.options.max_age_secs > 0
            && now.signed_duration_since(self.last_cleanup)
                >= ChronoDuration::seconds(CLEANUP_INTERVAL_SECS)
    }

    fn cleanup(&mut self, now: &DateTime<Utc>) {
        self.last_cleanup = now.clone();
        let Ok(entries) = fs::read_dir(&self.dir) else {
            return;
        };

        let mut candidates = Vec::new();
        let prefix = format!("{}.", self.base_name);
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if !file_type.is_file() {
                continue;
            }

            let is_current = path == self.current_path;
            let Some(name) = entry.file_name().to_str().map(|name| name.to_string()) else {
                continue;
            };
            if !is_current && !name.starts_with(&prefix) {
                continue;
            }

            let Ok(metadata) = entry.metadata() else {
                continue;
            };
            let modified = metadata.modified().unwrap_or(UNIX_EPOCH);
            candidates.push(LogFileCandidate {
                path,
                modified,
                is_current,
            });
        }

        if self.options.max_age_secs > 0 {
            let cutoff = system_time_from_utc(now)
                .checked_sub(Duration::from_secs(self.options.max_age_secs))
                .unwrap_or(UNIX_EPOCH);
            candidates.retain(|candidate| {
                if candidate.is_current || candidate.modified >= cutoff {
                    true
                } else {
                    let _ = fs::remove_file(&candidate.path);
                    false
                }
            });
        }

        if self.options.max_files > 0 && candidates.len() > self.options.max_files {
            let mut archives: Vec<_> = candidates
                .into_iter()
                .filter(|candidate| !candidate.is_current)
                .collect();
            archives.sort_by_key(|candidate| candidate.modified);
            let mut total = archives.len() + 1;
            for candidate in archives {
                if total <= self.options.max_files {
                    break;
                }
                let _ = fs::remove_file(candidate.path);
                total -= 1;
            }
        }
    }
}

impl Write for BoundedFileAppender {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let now = self.now();
        let rotated_by_time = self.refresh_active_path(&now)?;
        if self.should_rotate_for_size(buf.len()) {
            self.rotate_for_size(&now)?;
            self.cleanup(&now);
        } else if rotated_by_time || self.cleanup_due(&now) {
            self.cleanup(&now);
        }

        let Some(file) = self.file.as_mut() else {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                "bounded log file is not open",
            ));
        };
        file.write_all(buf)?;
        self.current_size = self.current_size.saturating_add(buf.len() as u64);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        if let Some(file) = self.file.as_mut() {
            file.flush()
        } else {
            Ok(())
        }
    }
}

struct LogFileCandidate {
    path: PathBuf,
    modified: SystemTime,
    is_current: bool,
}

fn open_append_file(path: &Path) -> io::Result<(File, u64)> {
    let mut options = OpenOptions::new();
    options.create(true).append(true);

    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) => {
            let Some(parent) = path
                .parent()
                .filter(|parent| !parent.as_os_str().is_empty())
            else {
                return Err(error);
            };
            fs::create_dir_all(parent)?;
            options.open(path)?
        }
    };
    let current_size = file.metadata()?.len();
    Ok((file, current_size))
}

fn active_path_for(
    dir: &Path,
    base_name: &str,
    rotation: LogRotation,
    now: &DateTime<Utc>,
) -> PathBuf {
    match rotation {
        LogRotation::Never => dir.join(base_name),
        LogRotation::Minutely | LogRotation::Hourly | LogRotation::Daily | LogRotation::Weekly => {
            dir.join(format!("{base_name}.{}", period_suffix_for(rotation, now)))
        }
    }
}

fn period_suffix_for(rotation: LogRotation, now: &DateTime<Utc>) -> String {
    match rotation {
        LogRotation::Never | LogRotation::Daily => now.format("%Y-%m-%d").to_string(),
        LogRotation::Hourly => now.format("%Y-%m-%d-%H").to_string(),
        LogRotation::Minutely => now.format("%Y-%m-%d-%H-%M").to_string(),
        LogRotation::Weekly => {
            let days_since_sunday = now.weekday().num_days_from_sunday() as i64;
            let week_start = now.date_naive() - ChronoDuration::days(days_since_sunday);
            week_start.format("%Y-%m-%d").to_string()
        }
    }
}

fn system_time_from_utc(now: &DateTime<Utc>) -> SystemTime {
    let duration = Duration::new(now.timestamp().unsigned_abs(), now.timestamp_subsec_nanos());
    if now.timestamp() >= 0 {
        UNIX_EPOCH + duration
    } else {
        UNIX_EPOCH - duration
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use tempfile::tempdir;

    use super::*;

    fn fixed_now() -> DateTime<Utc> {
        DateTime::<Utc>::from(UNIX_EPOCH + Duration::from_secs(10))
    }

    fn options(path: PathBuf) -> FileLogOptions {
        FileLogOptions {
            path: path.to_string_lossy().to_string(),
            rotation: LogRotation::Never,
            max_size_bytes: 0,
            max_files: 0,
            max_age_secs: 0,
        }
    }

    fn matching_logs(dir: &Path) -> Vec<PathBuf> {
        let mut files: Vec<_> = fs::read_dir(dir)
            .unwrap()
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .map(|name| name.starts_with("tupoproxy.log"))
                    .unwrap_or(false)
            })
            .collect();
        files.sort();
        files
    }

    #[test]
    fn size_rotation_keeps_latest_write_in_active_file() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("tupoproxy.log");
        let mut options = options(path.clone());
        options.max_size_bytes = 6;

        let mut appender = BoundedFileAppender::with_now(options, Box::new(fixed_now)).unwrap();
        appender.write_all(b"abc\n").unwrap();
        appender.write_all(b"def\n").unwrap();
        appender.flush().unwrap();

        assert_eq!(fs::read_to_string(path).unwrap(), "def\n");
        assert_eq!(matching_logs(dir.path()).len(), 2);
    }

    #[test]
    fn max_files_retention_removes_oldest_archives() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("tupoproxy.log");
        let mut options = options(path);
        options.max_size_bytes = 4;
        options.max_files = 2;

        let mut appender = BoundedFileAppender::with_now(options, Box::new(fixed_now)).unwrap();
        for line in [b"aa\n", b"bb\n", b"cc\n", b"dd\n"] {
            appender.write_all(line).unwrap();
        }
        appender.flush().unwrap();

        assert!(matching_logs(dir.path()).len() <= 2);
    }

    #[cfg(unix)]
    #[test]
    fn max_age_retention_removes_old_archives() {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;

        let dir = tempdir().unwrap();
        let path = dir.path().join("tupoproxy.log");
        let old_archive = dir.path().join("tupoproxy.log.20000101000000.0");
        fs::write(&old_archive, "old").unwrap();

        let c_path = CString::new(old_archive.as_os_str().as_bytes()).unwrap();
        let times = [
            libc::timespec {
                tv_sec: 0,
                tv_nsec: 0,
            },
            libc::timespec {
                tv_sec: 0,
                tv_nsec: 0,
            },
        ];
        let rc = unsafe { libc::utimensat(libc::AT_FDCWD, c_path.as_ptr(), times.as_ptr(), 0) };
        assert_eq!(rc, 0);

        let mut options = options(path);
        options.max_age_secs = 1;
        let _appender = BoundedFileAppender::with_now(options, Box::new(fixed_now)).unwrap();

        assert!(!old_archive.exists());
    }
}
