#![cfg(feature = "http")]
use localsend::http::{
    server::{
        integration::{create_key, ApiConfig, Limits, Scope, WorkspaceGrant, PREFIX},
        start_with_port,
        web::WebConfig,
        ServerConfigV2, ServerHandle,
    },
    state::ClientInfo,
};
use serde_json::Value;
use tokio::sync::{mpsc, oneshot};

const UNLIMITED: Limits = Limits {
    per_second: 0,
    per_minute: 0,
    concurrent: 0,
};
struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    root: String,
    secret: String,
    config: ApiConfig,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new() -> Self {
        let (stop, rx) = oneshot::channel();
        let (events, mut received) = mpsc::channel(4);
        tokio::spawn(async move { while received.recv().await.is_some() {} });
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "Quota fixture".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "fixture".into(),
            },
            None,
            Some(ServerConfigV2 {
                pin: None,
                verify_checksums: false,
                event_tx: events,
            }),
            WebConfig::default(),
            rx,
        )
        .await
        .unwrap();
        let key = create_key(
            "Lifecycle".into(),
            WorkspaceGrant {
                scopes: vec![Scope::Service],
                workspaces: vec![],
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
        server
            .configure_integration_api(&serde_json::to_string(&config).unwrap())
            .await
            .unwrap();
        let root = format!("http://127.0.0.1:{}{PREFIX}", server.port());
        Self {
            server,
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(std::time::Duration::from_secs(5))
                .build()
                .unwrap(),
            root,
            secret: key.secret,
            config,
            stop: Some(stop),
        }
    }
    async fn apply(&mut self) {
        self.config.revision += 1;
        self.server
            .configure_integration_api(&serde_json::to_string(&self.config).unwrap())
            .await
            .unwrap();
    }
    async fn request(&self, key: bool, status: u16) -> Value {
        let request = self.client.get(format!("{}/status", self.root));
        let response = if key {
            request.bearer_auth(&self.secret)
        } else {
            request
        }
        .send()
        .await
        .unwrap();
        assert_eq!(response.status().as_u16(), status);
        response.json().await.unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
    }
}
#[tokio::test]
async fn paused_valid_bearer_is_denied_over_http_while_anonymous_reads_still_work() {
    let mut f = Fixture::new().await;
    f.request(true, 200).await;
    let original = f.config.keys[0].clone();
    f.config.keys[0].enabled = false;
    f.apply().await;
    assert_eq!(f.request(true, 403).await["error"]["code"], "key_paused");
    f.request(false, 200).await;
    let snapshot: Value = serde_json::from_str(&f.server.integration_api_snapshot()).unwrap();
    assert_eq!(snapshot["keys"][0]["enabled"], false);
    assert!(!snapshot.to_string().contains(&original.verifier));
    f.config.keys[0].enabled = true;
    f.apply().await;
    f.request(true, 200).await;
    assert_eq!(f.config.keys[0].id, original.id);
    assert_eq!(f.config.keys[0].verifier, original.verifier);
}
#[tokio::test]
async fn override_then_pause_resume_preserves_http_minute_usage() {
    let mut f = Fixture::new().await;
    f.config.keys[0].limits = Some(Limits {
        per_minute: 2,
        ..UNLIMITED
    });
    f.apply().await;
    f.request(true, 200).await;
    f.config.keys[0].enabled = false;
    f.apply().await;
    f.config.keys[0].enabled = true;
    f.apply().await;
    f.request(true, 200).await;
    assert_eq!(f.request(true, 429).await["error"]["reason"], "key.minute");
    f.config.keys[0].limits = Some(UNLIMITED);
    f.apply().await;
    f.request(true, 200).await;
    f.config.keys[0].limits = Some(Limits {
        per_minute: 3,
        ..UNLIMITED
    });
    f.apply().await;
    assert_eq!(f.request(true, 429).await["error"]["reason"], "key.minute");
}
#[tokio::test]
async fn zero_quota_http_headers_keep_finite_global_bound_and_unlimited_sentinel() {
    let mut f = Fixture::new().await;
    let response = f
        .client
        .get(format!("{}/status", f.root))
        .bearer_auth(&f.secret)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(
        response.headers()["x-legnasend-remaining-second"],
        "4294967295"
    );
    assert_eq!(
        response.headers()["x-legnasend-remaining-minute"],
        "4294967295"
    );
    response.bytes().await.unwrap();
    f.config.global_limits.per_minute = 3;
    f.apply().await;
    let response = f
        .client
        .get(format!("{}/status", f.root))
        .bearer_auth(&f.secret)
        .send()
        .await
        .unwrap();
    assert_eq!(response.headers()["x-legnasend-remaining-minute"], "1");
    response.bytes().await.unwrap();
    f.request(false, 200).await;
    assert_eq!(
        f.request(true, 429).await["error"]["reason"],
        "global.minute"
    );
}
