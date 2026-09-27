//! HTTP admission and authority composition for bounded archive metadata tickets.
use super::archive_selections::{Authority, Caller, Context, Error, Selection, Ticket};
use super::*;
fn map_error(error: Error) -> AppError {
    status(match error {
        Error::Invalid => StatusCode::BAD_REQUEST,
        Error::TooLarge => StatusCode::PAYLOAD_TOO_LARGE,
        Error::Busy => StatusCode::TOO_MANY_REQUESTS,
        Error::Gone => StatusCode::GONE,
        Error::Forbidden => StatusCode::FORBIDDEN,
    })
}
fn context(ws: &Workspace, grant: Option<&Grant>, peer: &str, origin: &str) -> Context {
    Context {
        owner: ws.document_owner.clone(),
        workspace: ws.config.id.clone(),
        generation: ws.config.generation,
        caller: if origin == "api" {
            Caller::Api
        } else {
            Caller::Browser(peer.into())
        },
        workspace_cancel: ws.version_stopped.clone(),
        authority: grant.map(|g| Authority {
            cancel: g.cancel.clone(),
            expires: g.expires,
        }),
    }
}
fn validate_selection(ws: &Workspace, selection: &Selection) -> Result<(), AppError> {
    if ws.config.document_tree.is_some() {
        if !selection.path.is_empty() && !documents::opaque(&selection.path)
            || selection.ids.iter().any(|id| !documents::opaque(id))
        {
            return Err(bad());
        }
    } else {
        validate_relative(&selection.path)?;
        for id in &selection.ids {
            let bytes = URL_SAFE_NO_PAD.decode(id).map_err(|_| bad())?;
            if URL_SAFE_NO_PAD.encode(&bytes) != *id {
                return Err(bad());
            }
            let value = String::from_utf8(bytes).map_err(|_| bad())?;
            validate_relative(&value)?;
            if value.is_empty() || value.rsplit_once('/').map_or("", |(p, _)| p) != selection.path {
                return Err(bad());
            }
        }
    }
    Ok(())
}
fn query(req: &Request<Incoming>) -> Result<HashMap<String, String>, AppError> {
    let raw = req.uri().query().unwrap_or("");
    if raw.len() > 8192 {
        return Err(bad());
    }
    let mut result = HashMap::new();
    for (k, v) in form_urlencoded::parse(raw.as_bytes()) {
        if result.insert(k.into_owned(), v.into_owned()).is_some() {
            return Err(bad());
        }
    }
    Ok(result)
}
impl DirectoryRegistry {
    pub(super) async fn browser_archive_selection(
        self: &Arc<Self>,
        req: &mut Request<Incoming>,
        peer: &str,
    ) -> Result<Response<BoxedBody>, AppError> {
        let path = req.uri().path().to_owned();
        let rest = path.strip_prefix(&format!("{API}/")).ok_or_else(bad)?;
        let parts: Vec<_> = rest.split('/').collect();
        if parts.len() != 2 || !matches!(parts[1], "prepare-archive" | "cancel-archive") {
            return Err(bad());
        }
        let ws = self.workspace(parts[0]).await?;
        let grant = ws.access.authorize(req.headers(), &ws.config.id)?;
        if req
            .headers()
            .get("sec-fetch-site")
            .and_then(|v| v.to_str().ok())
            == Some("cross-site")
        {
            return Err(status(StatusCode::FORBIDDEN));
        }
        self.archive_selection_request(
            req,
            ws,
            query(req)?,
            grant,
            peer,
            "browser",
            API,
            parts[1] == "cancel-archive",
        )
        .await
    }
    pub(in crate::http::server) async fn integration_archive_selection(
        self: &Arc<Self>,
        req: &mut Request<Incoming>,
        workspace: &str,
        query: HashMap<String, String>,
        scope: &super::super::integration::WorkspaceGrant,
        anonymous: bool,
        authority: Grant,
        closing: bool,
    ) -> Result<Response<BoxedBody>, AppError> {
        if !scope.allows(workspace) {
            return Err(status(StatusCode::NOT_FOUND));
        }
        let ws = self.workspace(workspace).await?;
        if anonymous && (!ws.config.visible || ws.access.protected()) {
            return Err(status(StatusCode::NOT_FOUND));
        }
        self.archive_selection_request(
            req,
            ws,
            query,
            Some(authority),
            "",
            "api",
            &format!("{}/workspaces", super::super::integration::PREFIX),
            closing,
        )
        .await
    }
    async fn archive_selection_request(
        self: &Arc<Self>,
        req: &mut Request<Incoming>,
        ws: Arc<Workspace>,
        query: HashMap<String, String>,
        grant: Option<Grant>,
        peer: &str,
        origin: &str,
        prefix: &str,
        closing: bool,
    ) -> Result<Response<BoxedBody>, AppError> {
        if query.len() != 1
            || query.get("generation").and_then(|s| s.parse::<u64>().ok())
                != Some(ws.config.generation)
        {
            return Err(status(StatusCode::CONFLICT));
        }
        if req
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(';').next())
            != Some("application/json")
        {
            return Err(status(StatusCode::UNSUPPORTED_MEDIA_TYPE));
        }
        let _admission = self
            .archive_preparations
            .clone()
            .try_acquire_owned()
            .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
        let max = if closing {
            1024
        } else {
            archive_selections::MAX_BODY
        };
        let mut body = Vec::new();
        let read = async {
            while let Some(frame) = req.body_mut().frame().await {
                let frame = frame.map_err(|_| bad())?;
                if let Ok(bytes) = frame.into_data() {
                    if body.len() + bytes.len() > max {
                        return Err(status(StatusCode::PAYLOAD_TOO_LARGE));
                    }
                    body.extend_from_slice(&bytes);
                }
            }
            Ok::<_, AppError>(())
        };
        tokio::select! {biased;
            _=ws.version_stopped.cancelled()=>return Err(status(StatusCode::GONE)),
            _=async{if let Some(g)=&grant {tokio::select!{_=g.cancel.cancelled()=>{},_=tokio::time::sleep_until(g.expires.into())=>{}}}else{std::future::pending::<()>().await;}}=>return Err(status(StatusCode::UNAUTHORIZED)),
            result=tokio::time::timeout(Duration::from_secs(10),read)=>result.map_err(|_|status(StatusCode::REQUEST_TIMEOUT))??,
        }
        let context = context(&ws, grant.as_ref(), peer, origin);
        if closing {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Cancel {
                selection: String,
            }
            let value: Cancel = serde_json::from_slice(&body).map_err(|_| bad())?;
            if !documents::opaque(&value.selection) {
                return Err(bad());
            }
            self.archive_selections
                .cancel(&value.selection, &context)
                .map_err(map_error)?;
            return Ok(json_response(json!({"cancelled":true})));
        }
        let selection = Selection::parse(&body).map_err(map_error)?;
        validate_selection(&ws, &selection)?;
        let selected = selection.ids.len();
        let ticket = self
            .archive_selections
            .prepare(context, selection)
            .map_err(map_error)?;
        let download_url = format!(
            "{prefix}/{}/archive?generation={}&selection={}",
            ws.config.id, ws.config.generation, ticket.id
        );
        Ok(json_response(
            json!({"selection":ticket.id,"selectedEntries":selected,"expiresIn":ticket.remaining(Instant::now()).as_secs().max(1),"downloadUrl":download_url}),
        ))
    }
    pub(super) async fn archive(
        self: &Arc<Self>,
        ws: Arc<Workspace>,
        req: &Request<Incoming>,
        grant: Option<Grant>,
        query: &HashMap<String, String>,
        peer: &str,
        origin: &'static str,
    ) -> Result<Response<BoxedBody>, AppError> {
        let Some(selection) = query.get("selection") else {
            return self
                .archive_inner(ws, req, grant, query, peer, origin, None)
                .await;
        };
        if query.len() != 2 || !query.contains_key("generation") || !documents::opaque(selection) {
            return Err(bad());
        }
        let ticket: Arc<Ticket> = self
            .archive_selections
            .resolve(selection, &context(&ws, grant.as_ref(), peer, origin))
            .map_err(map_error)?;
        let effective = HashMap::from([
            ("generation".into(), ws.config.generation.to_string()),
            ("path".into(), ticket.selection.path.clone()),
        ]);
        let mut response = tokio::select! {biased;
            _=ticket.ended()=>return Err(status(StatusCode::GONE)),
            result=self.archive_inner(ws,req,grant,&effective,peer,origin,Some(ticket.clone()))=>result?,
        };
        let body = std::mem::replace(response.body_mut(), response::empty_body());
        let stream = body
            .into_data_stream()
            .take_until(async move { ticket.ended().await })
            .map(|item| item.map(Frame::data));
        *response.body_mut() = BodyExt::boxed(StreamBody::new(stream));
        Ok(response)
    }
}
