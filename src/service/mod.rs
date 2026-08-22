//! Service manager integration for tupoproxy.
//!
//! Supports generating service files for:
//! - systemd (Linux)
//! - OpenRC (Alpine, Gentoo)
//! - rc.d (FreeBSD)

use std::path::Path;

/// Detected init/service system.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InitSystem {
    /// systemd (most modern Linux distributions)
    Systemd,
    /// OpenRC (Alpine, Gentoo, some BSDs)
    OpenRC,
    /// FreeBSD rc.d
    FreeBSDRc,
    /// No known init system detected
    Unknown,
}

impl std::fmt::Display for InitSystem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InitSystem::Systemd => write!(f, "systemd"),
            InitSystem::OpenRC => write!(f, "OpenRC"),
            InitSystem::FreeBSDRc => write!(f, "FreeBSD rc.d"),
            InitSystem::Unknown => write!(f, "unknown"),
        }
    }
}

/// Detects the init system in use on the current host.
pub fn detect_init_system() -> InitSystem {
    // Check for systemd first (most common on Linux)
    if Path::new("/run/systemd/system").exists() {
        return InitSystem::Systemd;
    }

    // Check for OpenRC
    if Path::new("/sbin/openrc-run").exists() || Path::new("/sbin/openrc").exists() {
        return InitSystem::OpenRC;
    }

    // Check for FreeBSD rc.d
    if Path::new("/etc/rc.subr").exists() && Path::new("/etc/rc.d").exists() {
        return InitSystem::FreeBSDRc;
    }

    // Fallback: check if systemctl exists even without /run/systemd
    if Path::new("/usr/bin/systemctl").exists() || Path::new("/bin/systemctl").exists() {
        return InitSystem::Systemd;
    }

    InitSystem::Unknown
}

/// Returns the default service file path for the given init system.
pub fn service_file_path(init_system: InitSystem) -> &'static str {
    match init_system {
        InitSystem::Systemd => "/etc/systemd/system/tupoproxy.service",
        InitSystem::OpenRC => "/etc/init.d/tupoproxy",
        InitSystem::FreeBSDRc => "/usr/local/etc/rc.d/tupoproxy",
        InitSystem::Unknown => "/etc/init.d/tupoproxy",
    }
}

/// Options for generating service files.
pub struct ServiceOptions<'a> {
    /// Path to the tupoproxy executable
    pub exe_path: &'a Path,
    /// Path to the configuration file
    pub config_path: &'a Path,
    /// User to run as (optional)
    pub user: Option<&'a str>,
    /// Group to run as (optional)
    pub group: Option<&'a str>,
    /// PID file path
    pub pid_file: &'a str,
    /// Working directory
    pub working_dir: Option<&'a str>,
    /// Description
    pub description: &'a str,
}

impl<'a> Default for ServiceOptions<'a> {
    fn default() -> Self {
        Self {
            exe_path: Path::new("/usr/local/bin/tupoproxy"),
            config_path: Path::new("/etc/tupoproxy/config.toml"),
            user: Some("tupoproxy"),
            group: Some("tupoproxy"),
            pid_file: "/var/run/tupoproxy.pid",
            working_dir: Some("/var/lib/tupoproxy"),
            description: "tupoproxy - Telegram MTProto Proxy",
        }
    }
}

/// Generates a service file for the given init system.
pub fn generate_service_file(init_system: InitSystem, opts: &ServiceOptions) -> String {
    match init_system {
        InitSystem::Systemd => generate_systemd_unit(opts),
        InitSystem::OpenRC => generate_openrc_script(opts),
        InitSystem::FreeBSDRc => generate_freebsd_rc_script(opts),
        InitSystem::Unknown => generate_systemd_unit(opts), // Default to systemd format
    }
}

/// Generates an enhanced systemd unit file.
fn generate_systemd_unit(opts: &ServiceOptions) -> String {
    let user_line = opts.user.map(|u| format!("User={}", u)).unwrap_or_default();
    let group_line = opts
        .group
        .map(|g| format!("Group={}", g))
        .unwrap_or_default();
    let working_dir = opts
        .working_dir
        .map(|d| format!("WorkingDirectory={}", d))
        .unwrap_or_default();

    format!(
        r#"[Unit]
Description={description}
Documentation=https://github.com/wasteprince/tupoproxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart={exe} --foreground --pid-file {pid_file} {config}
ExecReload=/bin/kill -HUP $MAINPID
PIDFile={pid_file}
Restart=always
RestartSec=5
{user}
{group}
{working_dir}

# Resource limits
LimitNOFILE=65535
LimitNPROC=4096

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
MemoryDenyWriteExecute=true
LockPersonality=true

# Allow binding to privileged ports and writing to specific paths
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
ReadWritePaths=/etc/tupoproxy /var/run /var/lib/tupoproxy

[Install]
WantedBy=multi-user.target
"#,
        description = opts.description,
        exe = opts.exe_path.display(),
        config = opts.config_path.display(),
        pid_file = opts.pid_file,
        user = user_line,
        group = group_line,
        working_dir = working_dir,
    )
}

/// Generates an OpenRC init script.
fn generate_openrc_script(opts: &ServiceOptions) -> String {
    let user = opts.user.unwrap_or("root");
    let group = opts.group.unwrap_or("root");

    format!(
        r#"#!/sbin/openrc-run
# OpenRC init script for tupoproxy

description="{description}"
command="{exe}"
command_args="--daemon --syslog --pid-file {pid_file} {config}"
command_user="{user}:{group}"
pidfile="{pid_file}"

depend() {{
    need net
    use logger
    after firewall
}}

start_pre() {{
    checkpath --directory --owner {user}:{group} --mode 0755 /var/run
    checkpath --directory --owner {user}:{group} --mode 0755 /var/lib/tupoproxy
    checkpath --directory --owner {user}:{group} --mode 0755 /var/log/tupoproxy
}}

reload() {{
    ebegin "Reloading ${{RC_SVCNAME}}"
    start-stop-daemon --signal HUP --pidfile "${{pidfile}}"
    eend $?
}}
"#,
        description = opts.description,
        exe = opts.exe_path.display(),
        config = opts.config_path.display(),
        pid_file = opts.pid_file,
        user = user,
        group = group,
    )
}

/// Generates a FreeBSD rc.d script.
fn generate_freebsd_rc_script(opts: &ServiceOptions) -> String {
    let user = opts.user.unwrap_or("root");
    let group = opts.group.unwrap_or("wheel");

    format!(
        r#"#!/bin/sh
#
# PROVIDE: tupoproxy
# REQUIRE: LOGIN NETWORKING
# KEYWORD: shutdown
#
# Add the following lines to /etc/rc.conf to enable tupoproxy:
#
# tupoproxy_enable="YES"
# tupoproxy_config="/etc/tupoproxy/config.toml"  # optional
# tupoproxy_user="tupoproxy"                      # optional
# tupoproxy_group="tupoproxy"                     # optional
#

. /etc/rc.subr

name="tupoproxy"
rcvar="tupoproxy_enable"
desc="{description}"

load_rc_config $name

: ${{tupoproxy_enable:="NO"}}
: ${{tupoproxy_config:="{config}"}}
: ${{tupoproxy_user:="{user}"}}
: ${{tupoproxy_group:="{group}"}}
: ${{tupoproxy_pidfile:="{pid_file}"}}

pidfile="${{tupoproxy_pidfile}}"
command="{exe}"
command_args="--daemon --syslog --pid-file ${{tupoproxy_pidfile}} ${{tupoproxy_config}}"

start_precmd="tupoproxy_prestart"
reload_cmd="tupoproxy_reload"
extra_commands="reload"

tupoproxy_prestart() {{
    install -d -o ${{tupoproxy_user}} -g ${{tupoproxy_group}} -m 755 /var/run
    install -d -o ${{tupoproxy_user}} -g ${{tupoproxy_group}} -m 755 /var/lib/tupoproxy
}}

tupoproxy_reload() {{
    if [ -f "${{pidfile}}" ]; then
        echo "Reloading ${{name}} configuration."
        kill -HUP $(cat ${{pidfile}})
    else
        echo "${{name}} is not running."
        return 1
    fi
}}

run_rc_command "$1"
"#,
        description = opts.description,
        exe = opts.exe_path.display(),
        config = opts.config_path.display(),
        pid_file = opts.pid_file,
        user = user,
        group = group,
    )
}

/// Installation instructions for each init system.
pub fn installation_instructions(init_system: InitSystem) -> &'static str {
    match init_system {
        InitSystem::Systemd => {
            r#"To install and enable the service:
  sudo systemctl daemon-reload
  sudo systemctl enable tupoproxy
  sudo systemctl start tupoproxy

To check status:
  sudo systemctl status tupoproxy

To view logs:
  journalctl -u tupoproxy -f

To reload configuration:
  sudo systemctl reload tupoproxy
"#
        }
        InitSystem::OpenRC => {
            r#"To install and enable the service:
  sudo chmod +x /etc/init.d/tupoproxy
  sudo rc-update add tupoproxy default
  sudo rc-service tupoproxy start

To check status:
  sudo rc-service tupoproxy status

To reload configuration:
  sudo rc-service tupoproxy reload
"#
        }
        InitSystem::FreeBSDRc => {
            r#"To install and enable the service:
  sudo chmod +x /usr/local/etc/rc.d/tupoproxy
  sudo sysrc tupoproxy_enable="YES"
  sudo service tupoproxy start

To check status:
  sudo service tupoproxy status

To reload configuration:
  sudo service tupoproxy reload
"#
        }
        InitSystem::Unknown => {
            r#"No supported init system detected.
You may need to create a service file manually or run tupoproxy directly:
  tupoproxy start /etc/tupoproxy/config.toml
"#
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_systemd_unit_generation() {
        let opts = ServiceOptions::default();
        let unit = generate_systemd_unit(&opts);
        assert!(unit.contains("[Unit]"));
        assert!(unit.contains("[Service]"));
        assert!(unit.contains("[Install]"));
        assert!(unit.contains("ExecReload="));
        assert!(unit.contains("PIDFile="));
    }

    #[test]
    fn test_openrc_script_generation() {
        let opts = ServiceOptions::default();
        let script = generate_openrc_script(&opts);
        assert!(script.contains("#!/sbin/openrc-run"));
        assert!(script.contains("depend()"));
        assert!(script.contains("reload()"));
    }

    #[test]
    fn test_freebsd_rc_script_generation() {
        let opts = ServiceOptions::default();
        let script = generate_freebsd_rc_script(&opts);
        assert!(script.contains("#!/bin/sh"));
        assert!(script.contains("PROVIDE: tupoproxy"));
        assert!(script.contains("run_rc_command"));
    }

    #[test]
    fn test_service_file_paths() {
        assert_eq!(
            service_file_path(InitSystem::Systemd),
            "/etc/systemd/system/tupoproxy.service"
        );
        assert_eq!(service_file_path(InitSystem::OpenRC), "/etc/init.d/tupoproxy");
        assert_eq!(
            service_file_path(InitSystem::FreeBSDRc),
            "/usr/local/etc/rc.d/tupoproxy"
        );
    }
}
