use crate::common::{get_backend_url, get_issuer};
use pretty_assertions::assert_eq;
use serde::Deserialize;
use std::error::Error;

mod common;

#[tokio::test]
async fn test_get_ping() -> Result<(), Box<dyn Error>> {
    let url = format!("{}/ping", get_backend_url());
    let res = reqwest::get(&url).await?;
    assert_eq!(res.status(), 200);
    Ok(())
}

// Re-defined and copy & pasted here to be able to get rid of lots of
// memory allocations in prod, because `Deserialize` will not work with
// `'static` lifetimes.
#[derive(Debug, Deserialize)]
pub struct WellKnown {
    pub issuer: String,
    pub authorization_endpoint: String,
    pub backchannel_logout_supported: bool,
    pub backchannel_logout_session_supported: bool,
    pub device_authorization_endpoint: String,
    pub token_endpoint: String,
    pub introspection_endpoint: String,
    pub userinfo_endpoint: String,
    pub end_session_endpoint: String,
    pub registration_endpoint: Option<String>,
    pub jwks_uri: String,
    pub grant_types_supported: Vec<String>,
    pub response_types_supported: Vec<String>,
    pub subject_types_supported: Vec<String>,
    pub id_token_signing_alg_values_supported: Vec<String>,
    pub token_endpoint_auth_methods_supported: Vec<String>,
    pub token_endpoint_auth_signing_alg_values_supported: Vec<String>,
    pub claims_supported: Vec<String>,
    pub claim_types_supported: Vec<String>,
    pub scopes_supported: Vec<String>,
    pub code_challenge_methods_supported: Vec<String>,
    pub dpop_signing_alg_values_supported: Vec<String>,
    pub service_documentation: String,
    pub ui_locales_supported: Vec<String>,
    pub claims_parameter_supported: bool,
    pub client_id_metadata_document_supported: bool,
}

#[tokio::test]
async fn test_get_well_known() -> Result<(), Box<dyn Error>> {
    let url = format!("{}/.well-known/openid-configuration", get_backend_url());
    let res = reqwest::get(&url).await?;

    assert_eq!(res.status(), 200);
    let content = res.json::<WellKnown>().await?;
    // strip trailing /
    assert_eq!(content.issuer[..content.issuer.len() - 1], get_issuer());
    // don't test the rest for now as it might change soon again

    Ok(())
}

// Regression for issue #1643: because the issuer carries a path
// (`.../auth/v1/`), RFC 8414 §3.1 mandates the AS-metadata URL be formed by
// INSERTING `/.well-known/oauth-authorization-server` between host and path.
// claude.ai probes exactly this path-insertion form; it must return the same
// JSON well-known document (not the SPA fallback) so the client can read
// `client_id_metadata_document_supported`.
#[tokio::test]
async fn test_get_well_known_oauth_rfc8414() -> Result<(), Box<dyn Error>> {
    let backend = get_backend_url();
    let root = backend.strip_suffix("/auth/v1").unwrap_or(&backend);

    // Both the no-slash form (probed by claude.ai) and the trailing-slash form
    // (issuer path is `/auth/v1/`) must return the well-known document, not the SPA.
    for url in [
        format!("{root}/.well-known/oauth-authorization-server/auth/v1"),
        format!("{root}/.well-known/oauth-authorization-server/auth/v1/"),
    ] {
        let res = reqwest::get(&url).await?;

        assert_eq!(res.status(), 200, "unexpected status for {url}");
        assert_eq!(
            res.headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok()),
            Some("application/json"),
            "unexpected content-type for {url}",
        );
        let content = res.json::<WellKnown>().await?;
        // strip trailing /
        assert_eq!(content.issuer[..content.issuer.len() - 1], get_issuer());
    }

    Ok(())
}

#[tokio::test]
async fn test_get_ready_and_health() -> Result<(), Box<dyn Error>> {
    // `/ready` is the orchestrator's probe. On a backend whose storage is up it must answer 200;
    // the 503 leg is covered by the unit test over the health watcher's verdict, because this
    // suite has no way to take the storage layer down under a running backend.
    let res = reqwest::get(format!("{}/ready", get_backend_url())).await?;
    assert_eq!(res.status(), 200);

    let res = reqwest::get(format!("{}/health", get_backend_url())).await?;
    assert_eq!(res.status(), 200);
    let body: serde_json::Value = res.json().await?;
    assert_eq!(body["db_healthy"], serde_json::Value::Bool(true));
    assert_eq!(body["cache_healthy"], serde_json::Value::Bool(true));

    Ok(())
}

#[derive(Debug, Deserialize)]
struct BackupListing {
    name: String,
    size: u64,
}

#[derive(Debug, Deserialize)]
struct BackupListings {
    local: Vec<BackupListing>,
}

/// The backup download must hand over the whole file, or fail.
///
/// A consumer takes a backup and downloads it in one go, and it has nothing but the status code
/// and the listing to check the result against. The download used to end the body on a read error
/// exactly as it ended it on EOF, so a short file arrived under a 200. Comparing the downloaded
/// length against the listed size is the end-to-end form of that check; `pump_reader`'s own tests
/// cover the failing-read path directly.
#[tokio::test]
async fn test_backup_download_is_complete() -> Result<(), Box<dyn Error>> {
    if std::env::var("HIQLITE").as_deref() == Ok("false") {
        // The backup routes exist only for the Hiqlite backend; with Postgres they answer 404 by
        // design. The Postgres leg of this suite therefore has nothing to assert here.
        return Ok(());
    }

    let (headers, _) = common::session_headers().await;
    let client = reqwest::Client::new();
    let url = format!("{}/backup", get_backend_url());

    // Consumers trigger a fresh backup and then take the newest one. Repeated rapid requests are
    // part of that usage, so they must not fail or race into a half-written file.
    for _ in 0..3 {
        let res = client.post(&url).headers(headers.clone()).send().await?;
        assert!(
            res.status().is_success(),
            "a backup trigger must succeed, got {}",
            res.status()
        );
    }

    let listings: BackupListings = client
        .get(&url)
        .headers(headers.clone())
        .send()
        .await?
        .json()
        .await?;
    assert!(
        !listings.local.is_empty(),
        "the triggered backups must be listed"
    );

    for listing in &listings.local {
        let res = client
            .get(format!(
                "{}/backup/local/{}",
                get_backend_url(),
                listing.name
            ))
            .headers(headers.clone())
            .send()
            .await?;
        assert_eq!(res.status(), 200);
        // The response declares how long the file is, so a client can detect a short body without
        // relying on the server aborting the connection.
        assert_eq!(
            res.content_length(),
            Some(listing.size),
            "the download of {} must declare its length",
            listing.name
        );
        let bytes = res.bytes().await?;

        assert_eq!(
            bytes.len() as u64,
            listing.size,
            "the download of {} is short: a truncated backup must never arrive under a 200",
            listing.name
        );
        assert!(
            bytes.starts_with(b"SQLite format 3\0"),
            "{} is not a SQLite database",
            listing.name
        );
    }

    Ok(())
}
