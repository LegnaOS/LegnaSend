//! Explicit all-native-task access, separate from per-principal transfer receipts.
use super::{
    contract::Operation,
    policy::{Denied, Lease},
};
use serde_json::{Value, json};
fn exact(v: &Value, keys: &[&str]) -> bool {
    v.as_object()
        .is_some_and(|m| m.len() == keys.len() && keys.iter().all(|k| m.contains_key(*k)))
}
fn uuid(v: &Value) -> bool {
    v.as_str().is_some_and(|s| {
        uuid::Uuid::parse_str(s).is_ok_and(|id| {
            id.get_version_num() == 4
                && id.get_variant() == uuid::Variant::RFC4122
                && id.to_string() == s
        })
    })
}
fn action(v: &Value) -> bool {
    ["cancel", "accept", "reject", "remove"]
        .iter()
        .any(|a| v == a)
}
pub(super) fn request(
    op: Operation,
    id: Option<&str>,
    lease: &Lease,
    payload: Option<Value>,
) -> Result<Value, Denied> {
    if lease.principal.is_none() || lease.grant.workspaces != ["*"] {
        return Err(Denied::new(403, "global_native_task_key_required"));
    }
    let mut out = json!({"operation":match op {Operation::NativeTasks=>"nativeTasks.list",Operation::ControlNativeTask=>"nativeTasks.control",Operation::SourceEndNotices=>"nativeTasks.sourceEndList",Operation::RetrySourceEndNotice=>"nativeTasks.sourceEndRetry",_=>return Err(Denied::new(400,"invalid_operation"))},"principal":lease.principal,"workspaces":["*"]});
    if op == Operation::ControlNativeTask {
        let body = payload.ok_or_else(|| Denied::new(400, "invalid_body"))?;
        if !exact(&body, &["epoch", "version", "action"])
            || !uuid(&body["epoch"])
            || !uuid(&body["version"])
            || !action(&body["action"])
        {
            return Err(Denied::new(400, "invalid_body"));
        }
        let id = id
            .filter(|v| uuid(&json!(v)))
            .ok_or_else(|| Denied::new(400, "invalid_identifier"))?;
        out["taskId"] = json!(id);
        out["change"] = body;
    } else if op == Operation::RetrySourceEndNotice {
        let body = payload.ok_or_else(|| Denied::new(400, "invalid_body"))?;
        if !exact(&body, &["version", "requestId"])
            || !uuid(&body["version"])
            || !uuid(&body["requestId"])
        {
            return Err(Denied::new(400, "invalid_body"));
        }
        let id = id
            .filter(|v| uuid(&json!(v)))
            .ok_or_else(|| Denied::new(400, "invalid_identifier"))?;
        out["noticeId"] = json!(id);
        out["body"] = body;
    } else if !matches!(op, Operation::NativeTasks | Operation::SourceEndNotices)
        || payload.is_some()
    {
        return Err(Denied::new(400, "invalid_body"));
    }
    Ok(out)
}
fn task(v: &Value) -> bool {
    exact(
        v,
        &[
            "id",
            "version",
            "direction",
            "phase",
            "fileCount",
            "totalBytes",
            "transferredBytes",
            "bytesPerSecond",
            "actions",
        ],
    ) && uuid(&v["id"])
        && uuid(&v["version"])
        && ["send", "receive"].iter().any(|s| v["direction"] == *s)
        && [
            "queued",
            "preparing",
            "waiting",
            "transferring",
            "succeeded",
            "failed",
            "canceled",
        ]
        .iter()
        .any(|s| v["phase"] == *s)
        && [
            "fileCount",
            "totalBytes",
            "transferredBytes",
            "bytesPerSecond",
        ]
        .iter()
        .all(|k| v[k].as_u64().is_some())
        && v["transferredBytes"].as_u64() <= v["totalBytes"].as_u64()
        && v["actions"].as_array().is_some_and(|a| {
            a.len() <= 4
                && a.iter().all(action)
                && a.iter().enumerate().all(|(i, v)| !a[..i].contains(v))
        })
}
fn cleanup(v: &Value, state: &Value) -> bool {
    matches!(state.as_str(), Some("removed" | "publishedPreserved"))
        && exact(v, &["receiptId", "removedFiles", "unlinkedBytes"])
        && uuid(&v["receiptId"])
        && v["removedFiles"].as_u64().is_some_and(|n| n <= 2)
        && v["unlinkedBytes"].as_u64().is_some()
        && (v["removedFiles"] != 0 || v["unlinkedBytes"] == 0)
}
fn notice(v: &Value) -> bool {
    let required = &[
        "id",
        "version",
        "peerLabel",
        "name",
        "state",
        "attempts",
        "updatedAtUnixMs",
    ];
    v.as_object().is_some_and(|m| {
        required.iter().all(|key| m.contains_key(*key))
            && m.keys()
                .all(|key| required.contains(&key.as_str()) || key == "cleanup")
            && m.get("cleanup")
                .is_none_or(|value| cleanup(value, &v["state"]))
    }) && uuid(&v["id"])
        && uuid(&v["version"])
        && [("peerLabel", 120), ("name", 255)]
            .iter()
            .all(|(key, max)| {
                v[key]
                    .as_str()
                    .is_some_and(|s| s.chars().count() <= *max && !s.chars().any(char::is_control))
            })
        && [
            "pending",
            "waitingPeer",
            "sharedSource",
            "busy",
            "authorizationRequired",
            "removed",
            "publishedPreserved",
            "unknown",
            "expired",
            "unsupported",
            "superseded",
        ]
        .iter()
        .any(|state| v["state"] == *state)
        && v["attempts"].as_u64().is_some()
        && v["updatedAtUnixMs"].as_u64().is_some()
}
pub(super) fn validate_response(raw: &str, request: &Value) -> Result<Value, &'static str> {
    if raw.len() > 256 * 1024 {
        return Err("Native task response too large");
    }
    let v: Value = serde_json::from_str(raw).map_err(|_| "Invalid native task response")?;
    if !exact(&v, &["status", "body"]) {
        return Err("Invalid native task envelope");
    }
    let b = &v["body"];
    if v["status"] != 200 {
        if [400, 403, 404, 409, 422, 429, 500, 503]
            .iter()
            .any(|s| v["status"] == *s)
            && exact(b, &["error"])
            && exact(&b["error"], &["code"])
            && b["error"]["code"]
                .as_str()
                .is_some_and(super::management::stable_code)
        {
            return Ok(v);
        }
        return Err("Invalid native task error");
    }
    let valid = if request["operation"] == "nativeTasks.list" {
        exact(b, &["epoch", "tasks", "truncated"])
            && uuid(&b["epoch"])
            && b["truncated"].is_boolean()
            && b["tasks"].as_array().is_some_and(|a| {
                a.len() <= 512 && a.iter().all(task) && {
                    let mut ids = std::collections::HashSet::new();
                    a.iter().all(|v| ids.insert(v["id"].as_str().unwrap()))
                }
            })
    } else if request["operation"] == "nativeTasks.sourceEndList" {
        exact(b, &["notices", "truncated"])
            && b["truncated"].is_boolean()
            && b["notices"].as_array().is_some_and(|a| {
                let mut ids = std::collections::HashSet::new();
                a.len() <= 512
                    && a.iter()
                        .all(|v| notice(v) && ids.insert(v["id"].as_str().unwrap()))
            })
    } else if request["operation"] == "nativeTasks.sourceEndRetry" {
        exact(b, &["notice", "accepted"])
            && b["accepted"] == true
            && notice(&b["notice"])
            && b["notice"]["id"] == request["noticeId"]
    } else if request["operation"] == "nativeTasks.control" {
        exact(b, &["epoch", "id", "action", "dispatched"])
            && b["epoch"] == request["change"]["epoch"]
            && b["id"] == request["taskId"]
            && b["action"] == request["change"]["action"]
            && b["dispatched"] == true
    } else {
        false
    };
    if !valid {
        return Err("Invalid native task body");
    }
    Ok(v)
}
#[cfg(test)]
mod tests {
    use super::*;
    const ID: &str = "11111111-1111-4111-8111-111111111111";
    #[test]
    fn redacted_contract_excludes_paths_and_overrun() {
        let mut t = json!({"id":ID,"version":ID,"direction":"receive","phase":"waiting","fileCount":2,"totalBytes":9,"transferredBytes":0,"bytesPerSecond":0,"actions":["accept","reject"]});
        assert!(task(&t));
        t["path"] = json!("/private/source");
        assert!(!task(&t));
        t.as_object_mut().unwrap().remove("path");
        t["transferredBytes"] = json!(10);
        assert!(!task(&t));
    }
    #[test]
    fn response_is_tied_to_requested_action_and_epoch() {
        let r = json!({"operation":"nativeTasks.control","taskId":ID,"change":{"epoch":ID,"action":"cancel"}});
        let mut v =
            json!({"status":200,"body":{"epoch":ID,"id":ID,"action":"cancel","dispatched":true}});
        assert!(validate_response(&v.to_string(), &r).is_ok());
        v["body"]["action"] = json!("accept");
        assert!(validate_response(&v.to_string(), &r).is_err());
    }
    #[test]
    fn source_end_redaction_and_reply_identity_are_enforced() {
        let mut n = json!({"id":ID,"version":ID,"peerLabel":"Phone","name":"file.txt","state":"pending","attempts":0,"updatedAtUnixMs":1});
        assert!(notice(&n));
        n["token"] = json!("secret");
        assert!(!notice(&n));
        n.as_object_mut().unwrap().remove("token");
        n["name"] = json!("bad\nname");
        assert!(!notice(&n));
        n["name"] = json!("file.txt");
        let request = json!({"operation":"nativeTasks.sourceEndRetry","noticeId":ID});
        let mut reply = json!({"status":200,"body":{"notice":n,"accepted":true}});
        assert!(validate_response(&reply.to_string(), &request).is_ok());
        reply["body"]["notice"]["id"] = json!("22222222-2222-4222-8222-222222222222");
        assert!(validate_response(&reply.to_string(), &request).is_err());
        let list = json!({"status":200,"body":{"notices":[n,n],"truncated":false}});
        assert!(
            validate_response(
                &list.to_string(),
                &json!({"operation":"nativeTasks.sourceEndList"})
            )
            .is_err()
        );
    }
}
