//! Credential lifecycle control: explicit global authority, bounded body and
//! narrowly validated responses. One-time creation secrets never enter records.
use super::{
    contract::Operation,
    policy::{Denied, Lease, Scope, WorkspaceGrant},
};
use serde_json::{Value, json};
fn exact(v: &Value, keys: &[&str]) -> bool {
    v.as_object()
        .is_some_and(|m| m.len() == keys.len() && keys.iter().all(|k| m.contains_key(*k)))
}
fn uuid(v: &Value) -> bool {
    v.as_str().is_some_and(|s| uuid::Uuid::parse_str(s).is_ok())
}
fn hex(v: &Value) -> bool {
    v.as_str().is_some_and(|s| {
        s.len() == 64
            && s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}
fn subset(parent: &WorkspaceGrant, child: &WorkspaceGrant) -> bool {
    child.scopes.iter().all(|s| parent.scopes.contains(s))
        && child
            .workspaces
            .iter()
            .all(|w| parent.workspaces.iter().any(|p| p == "*" || p == w))
}
pub(super) fn request(
    op: Operation,
    identity: Option<&str>,
    lease: &Lease,
    payload: Option<Value>,
) -> Result<Value, Denied> {
    if lease.principal.is_none()
        || !lease.grant.scopes.contains(&Scope::KeysManage)
        || !lease.grant.workspaces.iter().any(|w| w == "*")
    {
        return Err(Denied::new(403, "global_key_required"));
    }
    let name = match op {
        Operation::ListKeys => "keys.list",
        Operation::CreateKey => "keys.create",
        Operation::ManageKey => "keys.manage",
        Operation::KeyReceipt => "keys.receipt",
        _ => return Err(Denied::new(400, "invalid_operation")),
    };
    let mut out = json!({"operation":name,"principal":lease.principal,"grant":lease.grant});
    if op == Operation::KeyReceipt {
        let id = json!(identity);
        if !uuid(&id) {
            return Err(Denied::new(400, "invalid_identity"));
        }
        out["requestId"] = id;
    }
    if op == Operation::ManageKey {
        let id = json!(identity);
        if !uuid(&id) {
            return Err(Denied::new(400, "invalid_identity"));
        }
        if id == json!(lease.principal) {
            return Err(Denied::new(403, "self_management_forbidden"));
        }
        out["keyId"] = id;
    }
    if matches!(op, Operation::CreateKey | Operation::ManageKey) {
        let body = payload.ok_or_else(|| Denied::new(400, "invalid_body"))?;
        if !hex(&body["version"]) || !uuid(&body["requestId"]) {
            return Err(Denied::new(400, "invalid_body"));
        }
        if op == Operation::CreateKey {
            if !exact(
                &body,
                &["version", "requestId", "name", "grant", "expiresAt"],
            ) || !body["name"].as_str().is_some_and(|s| {
                !s.trim().is_empty() && s.len() <= 256 && !s.chars().any(char::is_control)
            }) {
                return Err(Denied::new(400, "invalid_body"));
            }
            let grant: WorkspaceGrant = serde_json::from_value(body["grant"].clone())
                .map_err(|_| Denied::new(400, "invalid_grant"))?;
            if !subset(&lease.grant, &grant) {
                return Err(Denied::new(403, "grant_escalation"));
            }
            if !body["expiresAt"].is_null()
                && !body["expiresAt"]
                    .as_u64()
                    .is_some_and(|v| v <= 253402300799)
            {
                return Err(Denied::new(400, "invalid_expiry"));
            }
        } else if !exact(&body, &["version", "requestId", "action"])
            || !["pause", "resume", "revoke"]
                .iter()
                .any(|a| body["action"] == *a)
        {
            return Err(Denied::new(400, "invalid_body"));
        }
        out["change"] = body;
    } else if payload.is_some() {
        return Err(Denied::new(400, "unexpected_body"));
    }
    Ok(out)
}
fn metadata(v: &Value, grant: &WorkspaceGrant) -> bool {
    exact(
        v,
        &[
            "id",
            "name",
            "grant",
            "createdAt",
            "expiresAt",
            "enabled",
            "limits",
        ],
    ) && uuid(&v["id"])
        && v["name"]
            .as_str()
            .is_some_and(|s| s.len() <= 256 && !s.chars().any(char::is_control))
        && v["createdAt"].as_u64().is_some()
        && (v["expiresAt"].is_null() || v["expiresAt"].as_u64().is_some())
        && v["enabled"].is_boolean()
        && (v["limits"].is_null()
            || exact(&v["limits"], &["perSecond", "perMinute", "concurrent"])
                && ["perSecond", "perMinute", "concurrent"]
                    .iter()
                    .all(|k| v["limits"][k].as_u64().is_some()))
        && serde_json::from_value::<WorkspaceGrant>(v["grant"].clone())
            .is_ok_and(|g| subset(grant, &g))
}
fn receipt(v: &Value, request: &Value) -> bool {
    exact(
        v,
        &[
            "principal",
            "requestId",
            "digest",
            "action",
            "keyId",
            "createdAt",
        ],
    ) && v["principal"] == request["principal"]
        && uuid(&v["requestId"])
        && uuid(&v["keyId"])
        && hex(&v["digest"])
        && v["createdAt"].as_u64().is_some()
        && ["create", "pause", "resume", "revoke"]
            .iter()
            .any(|a| v["action"] == *a)
        && (request["operation"] != "keys.create" || v["action"] == "create")
        && (request["operation"] != "keys.manage"
            || (v["action"] == request["change"]["action"] && v["keyId"] == request["keyId"]))
        && &v["requestId"]
            == if request["operation"] == "keys.receipt" {
                &request["requestId"]
            } else {
                &request["change"]["requestId"]
            }
}
pub(super) fn validate_response(raw: &str, request: &Value) -> Result<Value, &'static str> {
    if raw.len() > 256 * 1024 {
        return Err("Key response too large");
    }
    let v: Value = serde_json::from_str(raw).map_err(|_| "Invalid key response")?;
    if !exact(&v, &["status", "body"]) {
        return Err("Invalid key envelope");
    }
    let status = v["status"].as_u64().unwrap_or(0);
    let b = &v["body"];
    if status != 200 && status != 201 {
        return if [400, 403, 404, 409, 422, 429, 500, 503].contains(&status)
            && exact(b, &["error"])
            && exact(&b["error"], &["code"])
            && b["error"]["code"]
                .as_str()
                .is_some_and(super::management::stable_code)
        {
            Ok(v)
        } else {
            Err("Invalid key error")
        };
    }
    let grant: WorkspaceGrant =
        serde_json::from_value(request["grant"].clone()).map_err(|_| "Invalid key grant")?;
    if request["operation"] == "keys.list" {
        if status == 200
            && exact(b, &["version", "keys"])
            && hex(&b["version"])
            && b["keys"]
                .as_array()
                .is_some_and(|keys| keys.len() <= 128 && keys.iter().all(|k| metadata(k, &grant)))
        {
            return Ok(v);
        }
    } else {
        let has_secret = b["secretAvailable"] == true;
        let keys = if has_secret {
            vec!["receipt", "applied", "secretAvailable", "secret"]
        } else {
            vec!["receipt", "applied", "secretAvailable"]
        };
        if exact(b, &keys)
            && receipt(&b["receipt"], request)
            && b["applied"].is_boolean()
            && b["secretAvailable"].is_boolean()
        {
            if !has_secret && status == 200 {
                return Ok(v);
            }
            if has_secret
                && status == 201
                && request["operation"] == "keys.create"
                && b["applied"] == true
            {
                if let Some(secret) = b["secret"].as_str() {
                    let prefix = format!("ls1.{}.", b["receipt"]["keyId"].as_str().unwrap());
                    if secret.strip_prefix(&prefix).is_some_and(|tail| {
                        tail.len() == 43
                            && tail
                                .bytes()
                                .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
                    }) {
                        return Ok(v);
                    }
                }
            }
        }
    }
    Err("Invalid key body")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn receipts_bind_action_and_target_not_just_request_id() {
        let id = "00000000-0000-4000-8000-000000000001";
        let other = "00000000-0000-4000-8000-000000000002";
        let request = json!({"operation":"keys.manage","principal":id,"keyId":other,
            "change":{"requestId":id,"action":"pause"}});
        let mut value = json!({"principal":id,"requestId":id,"keyId":other,
            "action":"pause","digest":"a".repeat(64),"createdAt":1});
        assert!(receipt(&value, &request));
        value["keyId"] = json!(id);
        assert!(!receipt(&value, &request));
        value["keyId"] = json!(other);
        value["action"] = json!("revoke");
        assert!(!receipt(&value, &request));
        let mut create = request.clone();
        create["operation"] = json!("keys.create");
        assert!(!receipt(&value, &create));
        value["action"] = json!("create");
        assert!(receipt(&value, &create));
    }
}
