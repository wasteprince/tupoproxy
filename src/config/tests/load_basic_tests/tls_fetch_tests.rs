use super::*;

#[test]
fn coexistence_deployment_example_loads() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("deploy/tupoproxy.toml.example");
    let cfg = ProxyConfig::load(path).expect("deployment example must remain valid");

    assert!(
        cfg.server
            .listeners
            .iter()
            .any(|listener| listener.port == Some(18443))
    );
    assert!(cfg.server.proxy_protocol);
    assert_eq!(cfg.censorship.tls_fingerprints.len(), 1);
    assert!(!cfg.censorship.mask);
    assert_eq!(cfg.censorship.unknown_sni_action, UnknownSniAction::Drop);
}

#[test]
fn tls_fetch_scope_default_is_empty() {
    let toml = r#"
        [censorship]
        tls_domain = "example.com"

        [access.users]
        user = "00000000000000000000000000000000"
    "#;
    let dir = std::env::temp_dir();
    let path = dir.join("tupoproxy_tls_fetch_scope_default_test.toml");
    std::fs::write(&path, toml).unwrap();
    let cfg = ProxyConfig::load(&path).unwrap();
    assert!(cfg.censorship.tls_fetch_scope.is_empty());
    let _ = std::fs::remove_file(path);
}

#[test]
fn tls_fetch_scope_is_trimmed_during_load() {
    let toml = r#"
        [censorship]
        tls_domain = "example.com"
        tls_fetch_scope = "  me  "

        [access.users]
        user = "00000000000000000000000000000000"
    "#;
    let dir = std::env::temp_dir();
    let path = dir.join("tupoproxy_tls_fetch_scope_trim_test.toml");
    std::fs::write(&path, toml).unwrap();
    let cfg = ProxyConfig::load(&path).unwrap();
    assert_eq!(cfg.censorship.tls_fetch_scope, "me");
    let _ = std::fs::remove_file(path);
}

#[test]
fn tls_fetch_scope_whitespace_becomes_empty() {
    let toml = r#"
        [censorship]
        tls_domain = "example.com"
        tls_fetch_scope = "   "

        [access.users]
        user = "00000000000000000000000000000000"
    "#;
    let dir = std::env::temp_dir();
    let path = dir.join("tupoproxy_tls_fetch_scope_blank_test.toml");
    std::fs::write(&path, toml).unwrap();
    let cfg = ProxyConfig::load(&path).unwrap();
    assert!(cfg.censorship.tls_fetch_scope.is_empty());
    let _ = std::fs::remove_file(path);
}

#[test]
fn tls_fetch_defaults_are_applied() {
    let toml = r#"
        [censorship]
        tls_domain = "example.com"

        [access.users]
        user = "00000000000000000000000000000000"
    "#;
    let dir = std::env::temp_dir();
    let path = dir.join("tupoproxy_tls_fetch_defaults_test.toml");
    std::fs::write(&path, toml).unwrap();
    let cfg = ProxyConfig::load(&path).unwrap();
    assert_eq!(
        cfg.censorship.tls_fetch.profiles,
        TlsFetchConfig::default().profiles
    );
    assert!(cfg.censorship.tls_fetch.strict_route);
    assert_eq!(cfg.censorship.tls_fetch.attempt_timeout_ms, 5_000);
    assert_eq!(cfg.censorship.tls_fetch.total_budget_ms, 15_000);
    assert_eq!(cfg.censorship.tls_fetch.profile_cache_ttl_secs, 600);
    let _ = std::fs::remove_file(path);
}

#[test]
fn tls_fetch_profiles_are_deduplicated_preserving_order() {
    let toml = r#"
        [censorship]
        tls_domain = "example.com"
        [censorship.tls_fetch]
        profiles = ["compat_tls12", "modern_chrome_like", "compat_tls12", "legacy_minimal"]

        [access.users]
        user = "00000000000000000000000000000000"
    "#;
    let dir = std::env::temp_dir();
    let path = dir.join("tupoproxy_tls_fetch_profiles_dedup_test.toml");
    std::fs::write(&path, toml).unwrap();
    let cfg = ProxyConfig::load(&path).unwrap();
    assert_eq!(
        cfg.censorship.tls_fetch.profiles,
        vec![
            TlsFetchProfile::CompatTls12,
            TlsFetchProfile::ModernChromeLike,
            TlsFetchProfile::LegacyMinimal
        ]
    );
    let _ = std::fs::remove_file(path);
}

#[test]
fn tls_fingerprints_bind_profiles_to_credential_domains() {
    let toml = r#"
        [censorship]
        tls_domain = "chrome.proxy.example"
        tls_domains = ["firefox.proxy.example"]
        tls_fingerprints = {
            "chrome.proxy.example" = "chrome",
            "firefox.proxy.example" = "firefox",
        }

        [access.users]
        user = "00000000000000000000000000000000"
    "#;
    let dir = std::env::temp_dir();
    let path = dir.join("tupoproxy_tls_fingerprints_test.toml");
    std::fs::write(&path, toml).unwrap();
    let cfg = ProxyConfig::load(&path).unwrap();
    assert_eq!(
        cfg.censorship
            .tls_fingerprints
            .get("chrome.proxy.example"),
        Some(&TlsFingerprintProfile::Chrome)
    );
    assert_eq!(
        cfg.censorship
            .tls_fingerprints
            .get("firefox.proxy.example"),
        Some(&TlsFingerprintProfile::Firefox)
    );
    let _ = std::fs::remove_file(path);
}

#[test]
fn tls_fingerprint_domain_is_added_to_generated_credential_domains() {
    let toml = r#"
        [censorship]
        tls_domain = "proxy.example"
        tls_fingerprints = { "firefox.proxy.example" = "firefox" }

        [access.users]
        user = "00000000000000000000000000000000"
    "#;
    let dir = std::env::temp_dir();
    let path = dir.join("tupoproxy_tls_fingerprint_domain_test.toml");
    std::fs::write(&path, toml).unwrap();
    let cfg = ProxyConfig::load(&path).unwrap();
    assert_eq!(
        cfg.censorship.tls_domains,
        vec!["firefox.proxy.example".to_string()]
    );
    let _ = std::fs::remove_file(path);
}

#[test]
fn tls_fetch_attempt_timeout_zero_is_rejected() {
    let toml = r#"
        [censorship]
        tls_domain = "example.com"
        [censorship.tls_fetch]
        attempt_timeout_ms = 0

        [access.users]
        user = "00000000000000000000000000000000"
    "#;
    let dir = std::env::temp_dir();
    let path = dir.join("tupoproxy_tls_fetch_attempt_timeout_zero_test.toml");
    std::fs::write(&path, toml).unwrap();
    let err = ProxyConfig::load(&path).unwrap_err().to_string();
    assert!(err.contains("censorship.tls_fetch.attempt_timeout_ms must be > 0"));
    let _ = std::fs::remove_file(path);
}

#[test]
fn tls_fetch_total_budget_zero_is_rejected() {
    let toml = r#"
        [censorship]
        tls_domain = "example.com"
        [censorship.tls_fetch]
        total_budget_ms = 0

        [access.users]
        user = "00000000000000000000000000000000"
    "#;
    let dir = std::env::temp_dir();
    let path = dir.join("tupoproxy_tls_fetch_total_budget_zero_test.toml");
    std::fs::write(&path, toml).unwrap();
    let err = ProxyConfig::load(&path).unwrap_err().to_string();
    assert!(err.contains("censorship.tls_fetch.total_budget_ms must be > 0"));
    let _ = std::fs::remove_file(path);
}

#[test]
fn invalid_ad_tag_is_disabled_during_load() {
    let toml = r#"
        [general]
        ad_tag = "not_hex"

        [censorship]
        tls_domain = "example.com"

        [access.users]
        user = "00000000000000000000000000000000"
    "#;
    let dir = std::env::temp_dir();
    let path = dir.join("tupoproxy_invalid_ad_tag_test.toml");
    std::fs::write(&path, toml).unwrap();
    let cfg = ProxyConfig::load(&path).unwrap();
    assert!(cfg.general.ad_tag.is_none());
    let _ = std::fs::remove_file(path);
}

#[test]
fn valid_ad_tag_is_preserved_during_load() {
    let toml = r#"
        [general]
        ad_tag = "00112233445566778899aabbccddeeff"

        [censorship]
        tls_domain = "example.com"

        [access.users]
        user = "00000000000000000000000000000000"
    "#;
    let dir = std::env::temp_dir();
    let path = dir.join("tupoproxy_valid_ad_tag_test.toml");
    std::fs::write(&path, toml).unwrap();
    let cfg = ProxyConfig::load(&path).unwrap();
    assert_eq!(
        cfg.general.ad_tag.as_deref(),
        Some("00112233445566778899aabbccddeeff")
    );
    let _ = std::fs::remove_file(path);
}
