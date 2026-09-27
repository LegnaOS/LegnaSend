//! Explicit global host operations. Never accept paths or return source names.
use super::{
    contract::Operation,
    policy::{Denied, Lease},
};
use serde_json::{Value, json};
fn exact(v: &Value, keys: &[&str]) -> bool {
    v.as_object()
        .is_some_and(|m| m.len() == keys.len() && keys.iter().all(|k| m.contains_key(*k)))
}
fn hex(v: &Value) -> bool {
    v.as_str().is_some_and(|s| {
        s.len() == 64
            && s.bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    })
}
fn text(v: &Value, n: usize) -> bool {
    v.as_str()
        .is_some_and(|s| s.chars().count() <= n && !s.chars().any(char::is_control))
}
pub(super) fn request(
    op: Operation,
    lease: &Lease,
    payload: Option<Value>,
) -> Result<Value, Denied> {
    if lease.principal.is_none() || !lease.grant.workspaces.iter().any(|v| v == "*") {
        return Err(Denied::new(403, "global_host_key_required"));
    }
    let name = match op {
        Operation::InspectCache => "cache.inspect",
        Operation::CleanupCache => "cache.cleanup",
        Operation::ReadSettings => "settings.read",
        Operation::UpdateSettings => "settings.update",
        _ => return Err(Denied::new(400, "invalid_operation")),
    };
    let mut result =
        json!({"operation":format!("host.{name}"),"principal":lease.principal,"workspaces":["*"]});
    if op == Operation::UpdateSettings {
        let body = payload.ok_or_else(|| Denied::new(400, "invalid_body"))?;
        if !exact(&body, &["version", "field", "value"])
            || !hex(&body["version"])
            || !setting(&body["field"], &body["value"])
        {
            return Err(Denied::new(400, "invalid_body"));
        }
        result["change"] = body;
    } else if payload.is_some() {
        return Err(Denied::new(400, "invalid_body"));
    }
    Ok(result)
}
fn retention_days(value: &Value) -> bool {
    value
        .as_i64()
        .is_some_and(|days| (-1..=3650).contains(&days))
}
fn retention_state(value: &Value) -> bool {
    exact(
        value,
        &["effectiveDays", "automaticCleanupPaused", "busy", "error"],
    ) && (value["effectiveDays"].is_null() || retention_days(&value["effectiveDays"]))
        && value["automaticCleanupPaused"].is_boolean()
        && value["busy"].is_boolean()
        && (!(value["effectiveDays"].is_null() || value["busy"] == true)
            || value["automaticCleanupPaused"] == true)
        && (value["error"].is_null()
            || ["invalid", "save", "apply", "restore"]
                .iter()
                .any(|code| value["error"] == *code))
}
fn setting(field: &Value, value: &Value) -> bool {
    match field.as_str().unwrap_or("") {
        "receiveCacheRetentionDays" => retention_days(value),
        "alias" => text(value, 120) && value.as_str().is_some_and(|v| !v.trim().is_empty()),
        "theme" => ["system", "light", "dark"].iter().any(|v| value == v),
        "locale" => {
            text(value, 32)
                && value.as_str().is_some_and(|v| {
                    !v.is_empty() && v.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
                })
        }
        "enableAnimations" | "autoFinish" | "createChecksums" | "verifyChecksums" => {
            value.is_boolean()
        }
        _ => false,
    }
}
pub(super) fn validate_response(raw: &str, request: &Value) -> Result<Value, &'static str> {
    if raw.len() > 256 * 1024 {
        return Err("Host response too large");
    }
    let v: Value = serde_json::from_str(raw).map_err(|_| "Invalid host response")?;
    if !exact(&v, &["status", "body"]) {
        return Err("Invalid host envelope");
    }
    let body = &v["body"];
    if v["status"] != 200 {
        if [400, 403, 404, 409, 422, 429, 500, 503]
            .iter()
            .any(|s| v["status"] == *s)
            && exact(body, &["error"])
            && exact(&body["error"], &["code"])
            && body["error"]["code"]
                .as_str()
                .is_some_and(super::management::stable_code)
        {
            return Ok(v);
        }
        return Err("Invalid host error");
    }
    let op = request["operation"].as_str().unwrap_or("");
    let valid = if op.starts_with("host.settings.") {
        exact(
            body,
            &[
                "version",
                "settings",
                "pendingRestart",
                "receiveCacheRetention",
            ],
        ) && retention_state(&body["receiveCacheRetention"])
            && body["pendingRestart"].as_array().is_some_and(|items| {
                items.len() <= 2
                    && items.iter().all(|v| v == "alias" || v == "verifyChecksums")
                    && (items.len() != 2 || items[0] != items[1])
            })
            && hex(&body["version"])
            && exact(
                &body["settings"],
                &[
                    "alias",
                    "theme",
                    "locale",
                    "enableAnimations",
                    "autoFinish",
                    "createChecksums",
                    "verifyChecksums",
                    "receiveCacheRetentionDays",
                ],
            )
            && body["settings"]
                .as_object()
                .unwrap()
                .iter()
                .all(|(k, v)| setting(&json!(k), v))
    } else {
        exact(
            body,
            &[
                "examined",
                "removedFiles",
                "removedRecords",
                "plannedBytes",
                "unlinkedBytes",
                "active",
                "retained",
                "failed",
                "budgetReached",
                "interrupted",
                "entries",
                "entriesTruncated",
            ],
        ) && [
            "examined",
            "removedFiles",
            "removedRecords",
            "plannedBytes",
            "unlinkedBytes",
            "active",
            "retained",
            "failed",
        ]
        .iter()
        .all(|k| body[k].as_u64().is_some())
            && ["budgetReached", "interrupted", "entriesTruncated"]
                .iter()
                .all(|k| body[k].is_boolean())
            && body["entries"].as_array().is_some_and(|entries| {
                entries.len() <= 128
                    && entries.iter().all(|e| {
                        exact(
                            e,
                            &[
                                "id",
                                "sourceKind",
                                "disposition",
                                "reason",
                                "plannedBytes",
                                "unlinkedBytes",
                            ],
                        ) && hex(&e["id"])
                            && (op != "host.cache.inspect"
                                || e["unlinkedBytes"] == 0
                                    && e["disposition"] != "removed"
                                    && e["disposition"] != "retired")
                            && ["unknown", "nativeReceive", "directoryUpload"]
                                .iter()
                                .any(|kind| e["sourceKind"] == *kind)
                            && [
                                "candidate",
                                "removed",
                                "retired",
                                "retained",
                                "active",
                                "failed",
                            ]
                            .iter()
                            .any(|kind| e["disposition"] == *kind)
                            && ["sourceKind", "disposition", "reason"].iter().all(|k| {
                                e[k].as_str().is_some_and(|s| {
                                    s.len() <= 80
                                        && !s.is_empty()
                                        && s.bytes().all(|c| {
                                            c.is_ascii_alphanumeric() || b"_-".contains(&c)
                                        })
                                })
                            })
                            && ["plannedBytes", "unlinkedBytes"]
                                .iter()
                                .all(|k| e[k].as_u64().is_some())
                    })
            })
            && (op != "host.cache.inspect"
                || body["removedFiles"] == 0
                    && body["removedRecords"] == 0
                    && body["unlinkedBytes"] == 0)
    };
    if valid {
        Ok(v)
    } else {
        Err("Invalid host body")
    }
}
