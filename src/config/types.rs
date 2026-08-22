//! Configuration data model split by serialized responsibility.
//!
//! Each private submodule owns one stable group of existing TOML fields while
//! this facade preserves the public crate configuration surface.

use chrono::{DateTime, Utc};
use ipnetwork::IpNetwork;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt;
use std::net::IpAddr;
use std::path::PathBuf;

use super::defaults::*;

mod access;
mod api;
mod censorship;
mod general;
mod general_impl;
mod links;
mod logging;
mod network;
mod policies;
mod server;

pub use access::{AccessConfig, CidrRateLimitKey, RateLimitBps};
#[allow(unused_imports)]
pub(crate) use access::{CidrAutoTemplate, CidrAutoTemplateFamily};
pub use api::{ApiConfig, ApiGrayAction};
pub use censorship::{
    AntiCensorshipConfig, ExclusiveMaskTarget, TlsFetchConfig, TlsFetchProfile,
    TlsFingerprintProfile, UnknownSniAction,
};
pub use general::GeneralConfig;
pub use links::{LinksConfig, ShowLink};
pub use logging::{LogLevel, LogRotation, LoggingConfig, LoggingDestination};
pub use network::{NetworkConfig, ProxyModes, UpstreamConfig, UpstreamType};
pub use policies::{
    MeBindStaleMode, MeFloorMode, MeRouteNoWriterMode, MeSocksKdfPolicy, MeTelemetryLevel,
    MeWriterPickMode, RstOnCloseMode, TelemetryConfig, UserMaxUniqueIpsMode,
};
#[allow(unused_imports)]
pub use server::{
    CLIENT_MSS_2IN8, CLIENT_MSS_EXTREME_LOW, CLIENT_MSS_MAX, CLIENT_MSS_MIN, CLIENT_MSS_TSPU,
    ConntrackBackend, ConntrackControlConfig, ConntrackMode, ConntrackPressureProfile,
    ListenerConfig, ServerConfig, SynLimitMode, TimeoutsConfig,
};

fn default_quota_state_path() -> PathBuf {
    PathBuf::from("tupoproxy.limit.json")
}
