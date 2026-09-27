use flutter_rust_bridge::frb;
use localsend::http::server::integration::{WorkspaceGrant, create_key, validate_configuration};
use localsend::serde_json;
use tokio::sync::Mutex;

/// Opaque creation result: neither Debug nor generated data models expose the secret.
#[frb(opaque)]
pub struct RsApiKeyDraft {
    record: String,
    secret: Mutex<Option<String>>,
}

impl RsApiKeyDraft {
    /// Verifier-bearing persistence record. Keep out of public state and diagnostics.
    pub async fn record(&self) -> String {
        self.record.clone()
    }

    /// Consume after persistence succeeds. Later calls never recover the plaintext.
    pub async fn take_secret(&self) -> Option<String> {
        self.secret.lock().await.take()
    }
}

pub async fn create_integration_api_key(
    name: String,
    grant: String,
    expires_at: Option<u64>,
) -> anyhow::Result<RsApiKeyDraft> {
    let grant: WorkspaceGrant =
        serde_json::from_str(&grant).map_err(|_| anyhow::anyhow!("Invalid API key grant"))?;
    let created = create_key(name, grant, expires_at)?;
    Ok(RsApiKeyDraft {
        record: serde_json::to_string(&created.record)?,
        secret: Mutex::new(Some(created.secret)),
    })
}

/// Validate before writing local preferences, including when receiving is off.
pub async fn validate_integration_api_configuration(config: String) -> anyhow::Result<()> {
    validate_configuration(&config)
}

#[cfg(test)]
mod tests {
    use super::*;
    use localsend::serde_json::json;

    #[tokio::test]
    async fn created_secret_is_consumed_once_and_not_in_the_persistence_record() {
        let draft = create_integration_api_key(
            "Fixture".into(),
            json!({"scopes":["service.read"],"workspaces":[]}).to_string(),
            None,
        )
        .await
        .unwrap();
        let secret = draft.take_secret().await.unwrap();
        let record = draft.record().await;
        assert!(!record.contains(&secret));
        assert_eq!(draft.take_secret().await, None);
        let record: serde_json::Value = serde_json::from_str(&record).unwrap();
        assert_eq!(record["verifier"].as_str().unwrap().len(), 64);
        assert!(record.get("secret").is_none());
    }

    #[tokio::test]
    async fn validation_works_without_a_running_server_and_redacts_errors() {
        let config = localsend::http::server::integration::ApiConfig::default();
        validate_integration_api_configuration(serde_json::to_string(&config).unwrap())
            .await
            .unwrap();
        let error = validate_integration_api_configuration("SECRET-IN-INVALID-JSON".into())
            .await
            .unwrap_err();
        assert!(!error.to_string().contains("SECRET"));
        assert!(
            create_integration_api_key("".into(), "{}".into(), None)
                .await
                .is_err()
        );
    }
}
