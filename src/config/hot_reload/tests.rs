use super::*;

fn sample_config() -> ProxyConfig {
    ProxyConfig::default()
}

fn write_reload_config(path: &Path, ad_tag: Option<&str>, server_port: Option<u16>) {
    let mut config = String::from(
        r#"
                [censorship]
                tls_domain = "example.com"

                [access.users]
                user = "00000000000000000000000000000000"
            "#,
    );

    if ad_tag.is_some() {
        config.push_str("\n[general]\n");
        if let Some(tag) = ad_tag {
            config.push_str(&format!("ad_tag = \"{tag}\"\n"));
        }
    }

    if let Some(port) = server_port {
        config.push_str("\n[server]\n");
        config.push_str(&format!("port = {port}\n"));
    }

    std::fs::write(path, config).unwrap();
}

fn temp_config_path(prefix: &str) -> PathBuf {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("{prefix}_{nonce}.toml"))
}

#[test]
fn overlay_applies_hot_and_preserves_non_hot() {
    let old = sample_config();
    let mut new = old.clone();
    new.general.hardswap = !old.general.hardswap;
    new.server.port = old.server.port.saturating_add(1);

    let applied = overlay_hot_fields(&old, &new);
    assert_eq!(applied.general.hardswap, new.general.hardswap);
    assert_eq!(applied.server.port, old.server.port);
}

#[test]
fn non_hot_only_change_does_not_change_hot_snapshot() {
    let old = sample_config();
    let mut new = old.clone();
    new.server.port = old.server.port.saturating_add(1);

    let applied = overlay_hot_fields(&old, &new);
    assert_eq!(
        HotFields::from_config(&old),
        HotFields::from_config(&applied)
    );
    assert_eq!(applied.server.port, old.server.port);
}

#[test]
fn bind_stale_mode_is_hot() {
    let old = sample_config();
    let mut new = old.clone();
    new.general.me_bind_stale_mode = match old.general.me_bind_stale_mode {
        MeBindStaleMode::Never => MeBindStaleMode::Ttl,
        MeBindStaleMode::Ttl => MeBindStaleMode::Always,
        MeBindStaleMode::Always => MeBindStaleMode::Never,
    };

    let applied = overlay_hot_fields(&old, &new);
    assert_eq!(
        applied.general.me_bind_stale_mode,
        new.general.me_bind_stale_mode
    );
    assert_ne!(
        HotFields::from_config(&old),
        HotFields::from_config(&applied)
    );
}

#[test]
fn keepalive_is_not_hot() {
    let old = sample_config();
    let mut new = old.clone();
    new.general.me_keepalive_interval_secs = old.general.me_keepalive_interval_secs + 5;

    let applied = overlay_hot_fields(&old, &new);
    assert_eq!(
        applied.general.me_keepalive_interval_secs,
        old.general.me_keepalive_interval_secs
    );
    assert_eq!(
        HotFields::from_config(&old),
        HotFields::from_config(&applied)
    );
}

#[test]
fn mixed_hot_and_non_hot_change_applies_only_hot_subset() {
    let old = sample_config();
    let mut new = old.clone();
    new.general.hardswap = !old.general.hardswap;
    new.general.use_middle_proxy = !old.general.use_middle_proxy;

    let applied = overlay_hot_fields(&old, &new);
    assert_eq!(applied.general.hardswap, new.general.hardswap);
    assert_eq!(
        applied.general.use_middle_proxy,
        old.general.use_middle_proxy
    );
    assert!(!config_equal(&applied, &new));
}

#[test]
fn listener_synlimit_fields_are_process_owned() {
    let mut old = sample_config();
    old.server.listeners.push(ListenerConfig {
        ip: "0.0.0.0".parse().unwrap(),
        port: Some(443),
        client_mss: None,
        synlimit: SynLimitMode::Iptables,
        synlimit_seconds: 60,
        synlimit_hitcount: 48,
        synlimit_burst: 1,
        synlimit_ios_seconds: 1,
        synlimit_ios_hitcount: 12,
        synlimit_ios_burst: 24,
        synlimit_hashlimit_expire_ms: 60_000,
        synlimit_hashlimit_size: 32_768,
        announce: None,
        announce_ip: None,
        proxy_protocol: None,
        reuse_allow: false,
    });
    let mut new = old.clone();
    new.server.port = 8443;
    new.server.listeners[0].synlimit_seconds = 120;
    new.server.listeners[0].synlimit_hitcount = 96;
    new.server.listeners[0].synlimit_burst = 2;
    new.server.listeners[0].synlimit_ios_seconds = 2;
    new.server.listeners[0].synlimit_ios_hitcount = 18;
    new.server.listeners[0].synlimit_ios_burst = 36;
    new.server.listeners[0].synlimit_hashlimit_expire_ms = 90_000;
    new.server.listeners[0].synlimit_hashlimit_size = 65_536;

    let applied = overlay_hot_fields(&old, &new);
    let listener = &applied.server.listeners[0];
    assert_eq!(applied.server.port, old.server.port);
    assert_eq!(
        listener.synlimit_seconds,
        old.server.listeners[0].synlimit_seconds
    );
    assert_eq!(
        listener.synlimit_hitcount,
        old.server.listeners[0].synlimit_hitcount
    );
    assert_eq!(
        listener.synlimit_burst,
        old.server.listeners[0].synlimit_burst
    );
    assert_eq!(
        listener.synlimit_hashlimit_size,
        old.server.listeners[0].synlimit_hashlimit_size
    );
    assert!(classify_config_changes(&old, &new).restart_required);
}

#[test]
fn reload_applies_hot_change_on_first_observed_snapshot() {
    let initial_tag = "11111111111111111111111111111111";
    let final_tag = "22222222222222222222222222222222";
    let path = temp_config_path("tupoproxy_hot_reload_stable");

    write_reload_config(&path, Some(initial_tag), None);
    let initial_cfg = Arc::new(ProxyConfig::load(&path).unwrap());
    let initial_hash = ProxyConfig::load_with_metadata(&path)
        .unwrap()
        .rendered_hash;
    let (config_tx, _config_rx) = watch::channel(initial_cfg.clone());
    let (log_tx, _log_rx) = watch::channel(initial_cfg.general.log_level.clone());
    let mut reload_state = ReloadState::new(Some(initial_hash));

    write_reload_config(&path, Some(final_tag), None);
    reload_config(&path, &config_tx, &log_tx, None, None, &mut reload_state).unwrap();
    assert_eq!(
        config_tx.borrow().general.ad_tag.as_deref(),
        Some(final_tag)
    );

    let _ = std::fs::remove_file(path);
}

#[test]
fn reload_keeps_hot_apply_when_non_hot_fields_change() {
    let initial_tag = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    let final_tag = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    let path = temp_config_path("tupoproxy_hot_reload_mixed");

    write_reload_config(&path, Some(initial_tag), None);
    let initial_cfg = Arc::new(ProxyConfig::load(&path).unwrap());
    let initial_hash = ProxyConfig::load_with_metadata(&path)
        .unwrap()
        .rendered_hash;
    let (config_tx, _config_rx) = watch::channel(initial_cfg.clone());
    let (log_tx, _log_rx) = watch::channel(initial_cfg.general.log_level.clone());
    let mut reload_state = ReloadState::new(Some(initial_hash));

    write_reload_config(&path, Some(final_tag), Some(initial_cfg.server.port + 1));
    reload_config(&path, &config_tx, &log_tx, None, None, &mut reload_state).unwrap();

    let applied = config_tx.borrow().clone();
    assert_eq!(applied.general.ad_tag.as_deref(), Some(final_tag));
    assert_eq!(applied.server.port, initial_cfg.server.port);

    let _ = std::fs::remove_file(path);
}

#[test]
fn classify_sni_change_requires_restart() {
    // censorship.* is not in overlay_hot_fields -> restart.
    let old = ProxyConfig::default();
    let mut new = ProxyConfig::default();
    new.censorship.tls_domain = "front.example".to_string();

    let class = classify_config_changes(&old, &new);
    assert!(class.restart_required);
    assert!(class.changed.iter().any(|c| c == "censorship"));
}

#[test]
fn classify_dns_overrides_change_is_hot() {
    // network.dns_overrides IS in overlay_hot_fields -> no restart.
    let old = ProxyConfig::default();
    let mut new = ProxyConfig::default();
    new.network.dns_overrides.push("1.1.1.1".to_string());

    let class = classify_config_changes(&old, &new);
    assert!(!class.restart_required);
    assert!(class.changed.iter().any(|c| c == "network"));
}

#[test]
fn classify_timeouts_change_requires_restart() {
    // timeouts.* is NOT in overlay_hot_fields -> restart.
    let old = ProxyConfig::default();
    let mut new = ProxyConfig::default();
    new.timeouts.client_handshake = old.timeouts.client_handshake + 1;

    let class = classify_config_changes(&old, &new);
    assert!(class.restart_required);
}

#[test]
fn reload_recovers_after_parse_error_on_next_attempt() {
    let initial_tag = "cccccccccccccccccccccccccccccccc";
    let final_tag = "dddddddddddddddddddddddddddddddd";
    let path = temp_config_path("tupoproxy_hot_reload_parse_recovery");

    write_reload_config(&path, Some(initial_tag), None);
    let initial_cfg = Arc::new(ProxyConfig::load(&path).unwrap());
    let initial_hash = ProxyConfig::load_with_metadata(&path)
        .unwrap()
        .rendered_hash;
    let (config_tx, _config_rx) = watch::channel(initial_cfg.clone());
    let (log_tx, _log_rx) = watch::channel(initial_cfg.general.log_level.clone());
    let mut reload_state = ReloadState::new(Some(initial_hash));

    std::fs::write(&path, "[access.users\nuser = \"broken\"\n").unwrap();
    assert!(reload_config(&path, &config_tx, &log_tx, None, None, &mut reload_state).is_none());
    assert_eq!(
        config_tx.borrow().general.ad_tag.as_deref(),
        Some(initial_tag)
    );

    write_reload_config(&path, Some(final_tag), None);
    reload_config(&path, &config_tx, &log_tx, None, None, &mut reload_state).unwrap();
    assert_eq!(
        config_tx.borrow().general.ad_tag.as_deref(),
        Some(final_tag)
    );

    let _ = std::fs::remove_file(path);
}
