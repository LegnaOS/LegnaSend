use super::*;

const UNLIMITED: Limits = Limits {
    per_second: 0,
    per_minute: 0,
    concurrent: 0,
};
fn setup() -> (Arc<Registry>, ApiConfig, HeaderMap) {
    let registry = Arc::new(Registry::new());
    let key = create_key(
        "Lifecycle".into(),
        WorkspaceGrant {
            scopes: vec![Scope::Service, Scope::Upload, Scope::Manage],
            workspaces: vec!["*".into()],
        },
        None,
    )
    .unwrap();
    let config = ApiConfig {
        revision: 1,
        enabled: true,
        auth_required: false,
        global_limits: UNLIMITED,
        key_limits: UNLIMITED,
        anonymous_limits: UNLIMITED,
        keys: vec![key.record],
        ..ApiConfig::default()
    };
    registry
        .configure(&serde_json::to_string(&config).unwrap())
        .unwrap();
    let mut headers = HeaderMap::new();
    headers.insert(
        header::AUTHORIZATION,
        format!("Bearer {}", key.secret).parse().unwrap(),
    );
    (registry, config, headers)
}
fn configure(registry: &Registry, config: &mut ApiConfig) {
    config.revision += 1;
    registry
        .configure(&serde_json::to_string(config).unwrap())
        .unwrap();
}
fn admit(registry: &Arc<Registry>, headers: &HeaderMap) -> Result<Lease, Denied> {
    registry
        .admit(
            headers,
            "127.0.0.1".into(),
            uuid::Uuid::new_v4().to_string(),
            "service",
            "GET",
            false,
        )
        .map(|(lease, err)| {
            assert!(err.is_none());
            lease
        })
}
fn accepted(registry: &Arc<Registry>, headers: &HeaderMap) -> Lease {
    admit(registry, headers).unwrap_or_else(|e| panic!("{} {} {:?}", e.status, e.code, e.reason))
}
fn denied(registry: &Arc<Registry>, headers: &HeaderMap, code: &str, reason: Option<&str>) {
    match admit(registry, headers) {
        Ok(_) => panic!("unexpected admission"),
        Err(e) => {
            assert_eq!(e.code, code);
            assert_eq!(e.reason.as_deref(), reason);
        }
    }
}
#[test]
fn zero_is_independent_for_every_dimension_and_layer() {
    for layer in 0..3 {
        for dimension in 0..3 {
            let (registry, mut config, key) = setup();
            let limits = match dimension {
                0 => Limits {
                    per_second: 1,
                    ..UNLIMITED
                },
                1 => Limits {
                    per_minute: 1,
                    ..UNLIMITED
                },
                _ => Limits {
                    concurrent: 1,
                    ..UNLIMITED
                },
            };
            match layer {
                0 => config.global_limits = limits,
                1 => config.key_limits = limits,
                _ => config.anonymous_limits = limits,
            };
            configure(&registry, &mut config);
            let headers = if layer == 2 { HeaderMap::new() } else { key };
            let first = accepted(&registry, &headers);
            let reason = format!(
                "{}.{}",
                ["global", "key", "anonymous"][layer],
                ["second", "minute", "concurrent"][dimension]
            );
            denied(&registry, &headers, "rate_limited", Some(&reason));
            match layer {
                0 => config.global_limits = UNLIMITED,
                1 => config.key_limits = UNLIMITED,
                _ => config.anonymous_limits = UNLIMITED,
            };
            configure(&registry, &mut config);
            let second = accepted(&registry, &headers);
            assert_eq!(second.remaining_second, u32::MAX);
            assert_eq!(second.remaining_minute, u32::MAX);
            drop((first, second));
        }
    }
}
#[test]
fn all_unlimited_still_obeys_independent_server_active_cap() {
    let (registry, _, headers) = setup();
    let mut leases = (0..64)
        .map(|_| accepted(&registry, &headers))
        .collect::<Vec<_>>();
    denied(
        &registry,
        &headers,
        "rate_limited",
        Some("server.concurrent"),
    );
    leases.pop();
    let another = accepted(&registry, &headers);
    assert_eq!(registry.snapshot()["activeResponses"], 64);
    drop((leases, another));
    assert_eq!(registry.snapshot()["activeResponses"], 0);
}
#[test]
fn overrides_keep_global_constraints_and_inherit_when_removed() {
    let (registry, mut config, headers) = setup();
    config.global_limits.per_minute = 3;
    config.key_limits.per_minute = 1;
    config.keys[0].limits = Some(Limits {
        per_minute: 2,
        ..UNLIMITED
    });
    configure(&registry, &mut config);
    let first = accepted(&registry, &headers);
    assert_eq!(first.remaining_minute, 1);
    drop(first);
    drop(accepted(&registry, &headers));
    denied(&registry, &headers, "rate_limited", Some("key.minute"));
    config.keys[0].limits = Some(UNLIMITED);
    configure(&registry, &mut config);
    drop(accepted(&registry, &headers));
    denied(&registry, &headers, "rate_limited", Some("global.minute"));
    config.global_limits = UNLIMITED;
    config.keys[0].limits = None;
    configure(&registry, &mut config);
    denied(&registry, &headers, "rate_limited", Some("key.minute"));
}
#[test]
fn override_does_not_cancel_active_work_or_erase_its_concurrent_credit() {
    let (registry, mut config, headers) = setup();
    let lease = accepted(&registry, &headers);
    config.keys[0].limits = Some(Limits {
        concurrent: 1,
        ..UNLIMITED
    });
    configure(&registry, &mut config);
    assert!(!lease.cancel.is_cancelled());
    denied(&registry, &headers, "rate_limited", Some("key.concurrent"));
    drop(lease);
    drop(accepted(&registry, &headers));
}
#[test]
fn paused_token_is_explicitly_denied_never_anonymous_and_resume_retains_identity() {
    let (registry, mut config, headers) = setup();
    let before = config.keys[0].clone();
    let lease = accepted(&registry, &headers);
    let authority = lease.upload_authority().unwrap();
    config.keys[0].enabled = false;
    configure(&registry, &mut config);
    assert!(lease.cancel.is_cancelled());
    denied(&registry, &headers, "key_paused", None);
    assert!(
        authority
            .publish(|| -> Result<(), hyper::StatusCode> { panic!("paused upload published") })
            .is_err()
    );
    assert_eq!(registry.state.lock().unwrap().anonymous.len(), 0);
    drop(accepted(&registry, &HeaderMap::new()));
    config.keys[0].enabled = true;
    configure(&registry, &mut config);
    assert_eq!(config.keys[0].id, before.id);
    assert_eq!(config.keys[0].verifier, before.verifier);
    let resumed = accepted(&registry, &headers);
    assert!(!resumed.cancel.is_cancelled());
    assert!(lease.cancel.is_cancelled());
}
#[test]
fn pause_resume_retains_used_minutes_and_detached_active_holds() {
    let (registry, mut config, headers) = setup();
    config.key_limits = Limits {
        per_minute: 2,
        concurrent: 1,
        ..UNLIMITED
    };
    configure(&registry, &mut config);
    let lease = accepted(&registry, &headers);
    let authority = lease.upload_authority().unwrap();
    config.keys[0].enabled = false;
    configure(&registry, &mut config);
    config.keys[0].enabled = true;
    configure(&registry, &mut config);
    drop(lease);
    denied(&registry, &headers, "rate_limited", Some("key.concurrent"));
    drop(authority);
    drop(accepted(&registry, &headers));
    denied(&registry, &headers, "rate_limited", Some("key.minute"));
}
#[test]
fn security_epoch_and_service_reenable_do_not_refill_quotas() {
    let (registry, mut config, headers) = setup();
    config.key_limits.per_minute = 1;
    configure(&registry, &mut config);
    drop(accepted(&registry, &headers));
    config.allowed_origins.push("https://example.test".into());
    configure(&registry, &mut config);
    denied(&registry, &headers, "rate_limited", Some("key.minute"));
    config.enabled = false;
    configure(&registry, &mut config);
    config.enabled = true;
    configure(&registry, &mut config);
    denied(&registry, &headers, "rate_limited", Some("key.minute"));
}
#[test]
fn old_records_default_enabled_and_inherited_while_malformed_overrides_reject() {
    let (_, config, _) = setup();
    let mut value = serde_json::to_value(config).unwrap();
    value["keys"][0].as_object_mut().unwrap().remove("enabled");
    value["keys"][0].as_object_mut().unwrap().remove("limits");
    let parsed = parse_configuration(&value.to_string()).unwrap();
    assert!(parsed.keys[0].enabled);
    assert!(parsed.keys[0].limits.is_none());
    for bad in [
        json!({}),
        json!({"perSecond":-1,"perMinute":0,"concurrent":0}),
        json!({"perSecond":0,"perMinute":0,"concurrent":65}),
        json!(false),
    ] {
        value["keys"][0]["limits"] = bad;
        assert!(parse_configuration(&value.to_string()).is_err());
    }
    value["keys"][0]["limits"] = json!(null);
    value["keys"][0]["enabled"] = json!("false");
    assert!(parse_configuration(&value.to_string()).is_err());
}

#[test]
fn one_keys_override_and_pause_never_modify_another_keys_credits() {
    let (registry, mut config, headers) = setup();
    let other = create_key(
        "Independent".into(),
        WorkspaceGrant {
            scopes: vec![Scope::Service],
            workspaces: vec![],
        },
        None,
    )
    .unwrap();
    let mut other_headers = HeaderMap::new();
    other_headers.insert(
        header::AUTHORIZATION,
        format!("Bearer {}", other.secret).parse().unwrap(),
    );
    config.keys.push(other.record);
    config.key_limits.per_minute = 1;
    config.keys[0].limits = Some(Limits {
        per_minute: 2,
        ..UNLIMITED
    });
    configure(&registry, &mut config);
    drop(accepted(&registry, &headers));
    drop(accepted(&registry, &other_headers));
    denied(
        &registry,
        &other_headers,
        "rate_limited",
        Some("key.minute"),
    );
    config.keys[0].enabled = false;
    configure(&registry, &mut config);
    denied(
        &registry,
        &other_headers,
        "rate_limited",
        Some("key.minute"),
    );
    config.keys[0].enabled = true;
    configure(&registry, &mut config);
    drop(accepted(&registry, &headers));
    denied(&registry, &headers, "rate_limited", Some("key.minute"));
}
