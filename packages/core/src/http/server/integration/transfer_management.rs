//! Opt-in device and transfer operations over the existing claimable host bridge.
//! The host owns discovery, the local selection and task receipts. No paths or
//! arbitrary remote targets are accepted from callers.
use super::{
    contract::Operation,
    policy::{Denied, Lease},
};
use serde_json::{Value, json};
fn uuid(value: &Value) -> bool {
    value.as_str().is_some_and(|s| {
        uuid::Uuid::parse_str(s).is_ok_and(|id| {
            id.get_version_num() == 4
                && id.get_variant() == uuid::Variant::RFC4122
                && id.to_string() == s
        })
    })
}
fn text(value: &Value, max: usize) -> bool {
    value
        .as_str()
        .is_some_and(|s| s.len() <= max && !s.chars().any(char::is_control))
}
fn exact(value: &Value, required: &[&str], optional: &[&str]) -> bool {
    value.as_object().is_some_and(|v| {
        required.iter().all(|k| v.contains_key(*k))
            && v.keys()
                .all(|k| required.contains(&k.as_str()) || optional.contains(&k.as_str()))
    })
}
fn workspace_payload(b: &Value) -> bool {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    exact(
        b,
        &["instanceId", "generation", "deviceId", "requestId", "files"],
        &["channelId", "localRouteId", "sourceMode"],
    ) && b
        .get("sourceMode")
        .is_none_or(|mode| mode == "documentSnapshot")
        && ["instanceId", "deviceId", "requestId"]
            .iter()
            .all(|k| uuid(&b[k]))
        && b.get("channelId").is_none_or(uuid)
        && b.get("localRouteId").is_none_or(uuid)
        && b["generation"]
            .as_u64()
            .is_some_and(|n| n > 0 && n <= 9007199254740991)
        && b["files"].as_array().is_some_and(|files| {
            let mut ids = std::collections::HashSet::new();
            !files.is_empty()
                && files.len() <= 128
                && files.iter().all(|f| {
                    if b.get("sourceMode").is_some() {
                        exact(f, &["id"], &[])
                            && uuid(&f["id"])
                            && ids.insert(f["id"].as_str().unwrap())
                    } else {
                        exact(f, &["id", "version"], &[])
                            && f["id"].as_str().is_some_and(|id| {
                                !id.is_empty()
                                    && id.len() <= 4096
                                    && ids.insert(id)
                                    && URL_SAFE_NO_PAD
                                        .decode(id)
                                        .is_ok_and(|v| URL_SAFE_NO_PAD.encode(v) == id)
                            })
                            && f["version"].as_str().is_some_and(|v| {
                                v.len() >= 3
                                    && v.len() <= 256
                                    && v.starts_with('"')
                                    && v.ends_with('"')
                                    && v[1..v.len() - 1]
                                        .bytes()
                                        .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
                            })
                    }
                })
        })
}
pub(super) fn validate_payload(op: Operation, payload: Option<&Value>) -> Result<(), Denied> {
    let valid = match op {
        Operation::WorkspaceSend => payload.is_some_and(workspace_payload),
        Operation::SendTransfer => payload.is_some_and(|b| {
            exact(
                b,
                &["deviceId", "selectionVersion", "requestId"],
                &["channelId", "localRouteId"],
            ) && ["deviceId", "selectionVersion", "requestId"]
                .iter()
                .all(|k| uuid(&b[k]))
                && b.get("channelId").is_none_or(uuid)
                && b.get("localRouteId").is_none_or(uuid)
        }),
        Operation::RetryTransfer => {
            payload.is_some_and(|b| exact(b, &["requestId"], &[]) && uuid(&b["requestId"]))
        }
        _ => payload.is_none(),
    };
    if valid {
        Ok(())
    } else {
        Err(Denied::new(400, "invalid_body"))
    }
}
pub(super) fn request(
    op: Operation,
    id: Option<&str>,
    lease: &Lease,
    payload: Option<Value>,
) -> Result<Value, Denied> {
    if lease.principal.is_none() {
        return Err(Denied::new(403, "transfer_key_required"));
    }
    if !lease.grant.workspaces.iter().any(|id| id == "*") {
        return Err(Denied::new(403, "wildcard_transfer_required"));
    }
    validate_payload(op, payload.as_ref())?;
    let name = match op {
        Operation::Devices => "devices",
        Operation::Device => "device",
        Operation::ScanDevices => "scan",
        Operation::SendSelection => "selection",
        Operation::SendTransfer => "send",
        Operation::WorkspaceSend => "workspaceSend",
        Operation::Transfers => "list",
        Operation::Transfer => "get",
        Operation::CancelTransfer => "cancel",
        Operation::RetryTransfer => "retry",
        Operation::RemoveTransfer => "remove",
        _ => return Err(Denied::new(400, "invalid_operation")),
    };
    let mut value = json!({"operation":format!("transfer.{name}"),"principal":lease.principal,"workspaces":["*"]});
    if matches!(
        op,
        Operation::Device
            | Operation::Transfer
            | Operation::CancelTransfer
            | Operation::RetryTransfer
            | Operation::RemoveTransfer
    ) {
        let id = id
            .filter(|id| uuid(&json!(id)))
            .ok_or_else(|| Denied::new(400, "invalid_identifier"))?;
        value[if op == Operation::Device {
            "deviceId"
        } else {
            "transferId"
        }] = json!(id);
    }
    if op == Operation::WorkspaceSend {
        let id = id
            .filter(|id| uuid(&json!(id)))
            .ok_or_else(|| Denied::new(400, "invalid_identifier"))?;
        value["workspaceId"] = json!(id);
    }
    if let Some(body) = payload {
        value
            .as_object_mut()
            .unwrap()
            .extend(body.as_object().unwrap().clone());
    }
    Ok(value)
}
fn device(value: &Value) -> bool {
    exact(value, &["id", "alias", "deviceType", "channels"], &[])
        && uuid(&value["id"])
        && text(&value["alias"], 1024)
        && value["deviceType"]
            .as_str()
            .is_some_and(|v| ["mobile", "desktop", "web", "headless", "server"].contains(&v))
        && value["channels"].as_array().is_some_and(|items| {
            items.len() <= 32
                && items.iter().all(|c| {
                    exact(c, &["id", "host", "port", "https"], &[])
                        && uuid(&c["id"])
                        && text(&c["host"], 128)
                        && c["host"].as_str().is_some_and(|s| {
                            let mut parts = s.split('%');
                            let ip = parts.next().unwrap_or("").parse::<std::net::IpAddr>();
                            let scope = parts.next();
                            ip.is_ok()
                                && parts.next().is_none()
                                && scope.is_none_or(|scope| {
                                    matches!(ip, Ok(std::net::IpAddr::V6(_)))
                                        && !scope.is_empty()
                                        && scope.len() <= 64
                                        && scope.bytes().all(|c| {
                                            c.is_ascii_alphanumeric() || b"_.-".contains(&c)
                                        })
                                })
                        })
                        && c["port"].as_u64().is_some_and(|p| (1..=65535).contains(&p))
                        && c["https"].is_boolean()
                })
        })
}
fn task(value: &Value) -> bool {
    exact(
        value,
        &[
            "id",
            "deviceId",
            "status",
            "fileCount",
            "totalBytes",
            "transferredBytes",
            "bytesPerSecond",
        ],
        &["result", "retryOf", "removed", "localRouteId"],
    ) && uuid(&value["id"])
        && uuid(&value["deviceId"])
        && text(&value["status"], 80)
        && value["status"]
            .as_str()
            .is_some_and(|v| ["queued", "running", "succeeded", "failed", "canceled"].contains(&v))
        && ["fileCount", "totalBytes", "transferredBytes"]
            .iter()
            .all(|k| value[k].as_u64().is_some())
        && value["bytesPerSecond"]
            .as_f64()
            .is_some_and(|n| n.is_finite() && n >= 0.)
        && value.get("retryOf").is_none_or(uuid)
        && value.get("localRouteId").is_none_or(uuid)
        && value.get("result").is_none_or(|v| {
            v.as_str().is_some_and(|v| {
                [
                    "waiting",
                    "recipientBusy",
                    "declined",
                    "tooManyAttempts",
                    "sending",
                    "finished",
                    "finishedWithErrors",
                    "canceledBySender",
                    "canceledByReceiver",
                ]
                .contains(&v)
            })
        })
        && value.get("removed").is_none_or(|v| v == true)
}
pub(super) fn validate_response(raw: &str, request: &Value) -> Result<Value, &'static str> {
    if raw.len() > 256 * 1024 {
        return Err("Transfer response too large");
    }
    let v: Value = serde_json::from_str(raw).map_err(|_| "Invalid transfer response")?;
    if !exact(&v, &["status", "body"], &[]) {
        return Err("Invalid transfer envelope");
    }
    let status = v["status"].as_u64().ok_or("Invalid transfer status")?;
    let body = &v["body"];
    if [400, 403, 404, 409, 422, 429, 500, 503].contains(&status) {
        if exact(body, &["error"], &[])
            && exact(&body["error"], &["code"], &[])
            && body["error"]["code"]
                .as_str()
                .is_some_and(super::management::stable_code)
        {
            return Ok(v);
        }
        return Err("Unsafe transfer error");
    }
    let operation = request["operation"].as_str().unwrap_or("");
    let expected = if matches!(
        operation,
        "transfer.scan" | "transfer.send" | "transfer.retry" | "transfer.workspaceSend"
    ) {
        202
    } else {
        200
    };
    if status != expected {
        return Err("Unexpected transfer status");
    }
    let valid = match operation {
        "transfer.devices" => {
            exact(
                body,
                &["devices", "truncated", "scanState"],
                &["localRoutes"],
            ) && body.get("localRoutes").is_none_or(|v| {
                v.as_array().is_some_and(|items| {
                    items.len() <= 64
                        && items.iter().all(|r| {
                            exact(r, &["id", "interfaceName", "address", "binding"], &[])
                                && uuid(&r["id"])
                                && text(&r["interfaceName"], 1024)
                                && r["interfaceName"].as_str().is_some_and(|s| !s.is_empty())
                                && r["address"].as_str().is_some_and(|s| {
                                    s.parse::<std::net::IpAddr>()
                                        .is_ok_and(|ip| !ip.is_unspecified() && !ip.is_multicast())
                                })
                                && r["binding"].as_str().is_some_and(|s| {
                                    ["interfaceAndSource", "sourceOnly", "androidNetwork"]
                                        .contains(&s)
                                })
                        })
                })
            }) && body["truncated"].is_boolean()
                && body["scanState"]
                    .as_str()
                    .is_some_and(|s| ["idle", "running", "failed"].contains(&s))
                && body["devices"]
                    .as_array()
                    .is_some_and(|items| items.len() <= 512 && items.iter().all(device))
        }
        "transfer.device" => {
            exact(body, &["device"], &[])
                && device(&body["device"])
                && body["device"]["id"] == request["deviceId"]
        }
        "transfer.scan" => {
            exact(body, &["accepted", "coalesced"], &[])
                && body["accepted"] == true
                && body["coalesced"].is_boolean()
        }
        "transfer.selection" => {
            exact(
                body,
                &[
                    "selectionVersion",
                    "totalCount",
                    "totalBytes",
                    "truncated",
                    "files",
                ],
                &[],
            ) && uuid(&body["selectionVersion"])
                && ["totalCount", "totalBytes"]
                    .iter()
                    .all(|k| body[k].as_u64().is_some())
                && body["truncated"].is_boolean()
                && body["files"].as_array().is_some_and(|items| {
                    items.len() <= 100
                        && items.iter().all(|f| {
                            exact(f, &["name", "size"], &[])
                                && text(&f["name"], 4096)
                                && f["name"].as_str().is_some_and(|s| !s.contains(['/', '\\']))
                                && f["size"].as_u64().is_some()
                        })
                })
        }
        "transfer.send" | "transfer.retry" | "transfer.workspaceSend" => {
            exact(body, &["task", "replayed"], &[])
                && task(&body["task"])
                && body["replayed"].is_boolean()
                && (!["transfer.send", "transfer.workspaceSend"].contains(&operation)
                    || body["task"]["deviceId"] == request["deviceId"])
                && (request.get("localRouteId").is_none()
                    || body["task"]["localRouteId"] == request["localRouteId"])
                && (operation != "transfer.retry"
                    || body["task"]["retryOf"] == request["transferId"])
        }
        "transfer.list" => {
            exact(body, &["tasks"], &[])
                && body["tasks"]
                    .as_array()
                    .is_some_and(|items| items.len() <= 512 && items.iter().all(task))
        }
        "transfer.get" | "transfer.cancel" => {
            exact(body, &["task"], &[])
                && task(&body["task"])
                && body["task"]["id"] == request["transferId"]
        }
        "transfer.remove" => {
            exact(body, &["removed", "id"], &[])
                && body["removed"] == true
                && body["id"] == request["transferId"]
        }
        _ => false,
    };
    if !valid {
        return Err("Unsafe transfer response fields");
    }
    Ok(v)
}

#[cfg(test)]
mod tests {
    #[test]
    fn document_snapshot_is_explicit_and_never_accepts_a_fake_version() {
        let id = "11111111-1111-4111-8111-111111111111";
        let mut body = serde_json::json!({"instanceId":id,"generation":1,"deviceId":id,"requestId":id,"sourceMode":"documentSnapshot","files":[{"id":id}]});
        assert!(super::workspace_payload(&body));
        body["files"][0]["version"] = serde_json::json!("fake");
        assert!(!super::workspace_payload(&body));
        body["files"][0].as_object_mut().unwrap().remove("version");
        body.as_object_mut().unwrap().remove("sourceMode");
        assert!(!super::workspace_payload(&body));
        body["sourceMode"] = serde_json::Value::Null;
        assert!(!super::workspace_payload(&body));
    }

    use super::*;
    const ID: &str = "11111111-1111-4111-8111-111111111111";
    fn channel(host: &str) -> Value {
        json!({"id":ID,"host":host,"port":53317,"https":false})
    }
    fn peer(channel: Value) -> Value {
        json!({"id":ID,"alias":"fixture","deviceType":"desktop","channels":[channel]})
    }
    #[test]
    fn device_responses_allow_scoped_ips_but_not_scope_path_injection() {
        for host in ["127.0.0.1", "::1", "fe80::1%en0", "fe80::1%3"] {
            assert!(device(&peer(channel(host))), "{host}");
        }
        for host in [
            "https://127.0.0.1",
            "127.0.0.1%/private/path",
            "fe80::1%/private/path",
            "fe80::1%en0%3",
            "fe80::1%",
            "hostname.local",
        ] {
            assert!(!device(&peer(channel(host))), "{host}");
        }
        let mut unknown = peer(channel("::1"));
        unknown["fingerprint"] = json!("secret");
        assert!(!device(&unknown));
    }
    #[test]
    fn input_ids_have_one_canonical_representation() {
        for id in [
            "11111111111141118111111111111111",
            "11111111-1111-1111-8111-111111111111",
            "11111111-1111-4111-C111-111111111111",
        ] {
            assert!(
                validate_payload(Operation::RetryTransfer, Some(&json!({"requestId":id}))).is_err()
            );
        }
        assert!(validate_payload(Operation::RetryTransfer, Some(&json!({"requestId":ID}))).is_ok());
    }
    #[test]
    fn errors_and_task_progress_never_forward_raw_paths_or_nonfinite_values() {
        let request = json!({"operation":"transfer.get","transferId":ID});
        assert!(
            validate_response(
                &json!({"status":409,"body":{"error":{"code":"transfer_busy"}}}).to_string(),
                &request
            )
            .is_ok()
        );
        for body in [
            json!({"error":{"code":"/private/path"}}),
            json!({"error":{"code":"transfer_busy","message":"Bearer secret"}}),
        ] {
            assert!(
                validate_response(&json!({"status":409,"body":body}).to_string(), &request)
                    .is_err()
            );
        }
        let mut task = json!({"id":ID,"deviceId":ID,"status":"running","fileCount":1,"totalBytes":100,"transferredBytes":50,"bytesPerSecond":5,"result":"sending"});
        assert!(super::task(&task));
        task["result"] = json!("unknown_internal_error_with_secret");
        assert!(!super::task(&task));
        task["result"] = json!("finished");
        task["bytesPerSecond"] = json!(-1);
        assert!(!super::task(&task));
    }
}

#[cfg(test)]
mod local_route_tests {
    use super::*;
    #[test]
    fn explicit_route_is_only_a_uuid_and_host_must_acknowledge_it() {
        let id = uuid::Uuid::new_v4().to_string();
        let mut body =
            json!({"deviceId":id,"selectionVersion":id,"requestId":id,"localRouteId":id});
        assert!(validate_payload(Operation::SendTransfer, Some(&body)).is_ok());
        body["localRouteId"] = json!("en0");
        assert!(validate_payload(Operation::SendTransfer, Some(&body)).is_err());
        body["localRouteId"] = json!({"address":"192.0.2.1"});
        assert!(validate_payload(Operation::SendTransfer, Some(&body)).is_err());
        let request = json!({"operation":"transfer.send","deviceId":id,"localRouteId":id});
        let mut reply = json!({"status":202,"body":{"replayed":false,"task":{"id":id,"deviceId":id,"status":"queued","fileCount":1,"totalBytes":1,"transferredBytes":0,"bytesPerSecond":0}}});
        assert!(validate_response(&reply.to_string(), &request).is_err());
        reply["body"]["task"]["localRouteId"] = json!(id);
        assert!(validate_response(&reply.to_string(), &request).is_ok());
    }
}
