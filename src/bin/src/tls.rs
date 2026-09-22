use rauthy_data::entity::ca_self_signed::SelfSignedCA;
use rauthy_data::rauthy_config::RauthyConfig;
use rauthy_error::ErrorResponse;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use std::io;
use std::time::Duration;
use time::OffsetDateTime;
use tokio::fs;
use tokio::task;
use tracing::{error, info, warn};

static SELF_SIGNED_DIR: &str = "tls";
static SELF_SIGNED_KEY: &str = "tls/self_signed_key.pem";
static SELF_SIGNED_CERT: &str = "tls/self_signed_cert.pem";

/// How long to wait before trying again after a failed certificate renewal.
const RENEWAL_RETRY: Duration = Duration::from_secs(300);

/// The shortest gap this will sleep before regenerating, so that a certificate which is already
/// at or past its renewal point cannot spin the loop.
const RENEWAL_FLOOR: Duration = Duration::from_secs(60);

/// Build the TLS server config.
///
/// Fallible on purpose. This runs after `DB::init()`, so a panic here would abort the process
/// with the storage layer still holding its locks, and the next start would treat the data
/// directory as an ungraceful shutdown. See the comment in `server::run`.
pub async fn load_tls() -> io::Result<rustls::ServerConfig> {
    let vars = &RauthyConfig::get().vars.tls;

    let (key_path, cert_path) = if vars.generate_self_signed {
        check_generate_tls().await?;
        (SELF_SIGNED_KEY.to_string(), SELF_SIGNED_CERT.to_string())
    } else {
        // unwrap is fine here, since it should never be called with both paths set anyway
        let key_path = vars
            .key_path
            .as_deref()
            .unwrap_or("tls/tls.key")
            .to_string();
        let cert_path = vars
            .cert_path
            .as_deref()
            .unwrap_or("tls/tls.crt")
            .to_string();

        if !fs::try_exists(&key_path).await.unwrap_or(false)
            || !fs::try_exists(&cert_path).await.unwrap_or(false)
        {
            error!(
                "Cannot load TLS certificates from {key_path} / {cert_path} - using self-signed as fallback"
            );
            check_generate_tls().await?;
            (SELF_SIGNED_KEY.to_string(), SELF_SIGNED_CERT.to_string())
        } else {
            (key_path, cert_path)
        }
    };

    // `tls_hot_reload::load_server_config` panics when it cannot load what it is given, and this
    // call site cannot catch that under `panic = "abort"`. Reading and parsing the material first
    // turns the reachable failures - unreadable file, empty file, something that is not PEM, a
    // certificate where a key belongs - into an error that the caller can act on, before the
    // library ever sees them.
    preflight_tls_material(&key_path, &cert_path).await?;

    Ok(tls_hot_reload::load_server_config(key_path, cert_path).await)
}

/// Check that the key and certificate can actually be read and parsed.
async fn preflight_tls_material(key_path: &str, cert_path: &str) -> io::Result<()> {
    let key = fs::read(key_path).await.map_err(|err| {
        io::Error::new(
            err.kind(),
            format!("Cannot read the TLS key {key_path}: {err}"),
        )
    })?;
    PrivateKeyDer::from_pem_slice(&key).map_err(|err| {
        io::Error::other(format!(
            "The TLS key {key_path} is not a usable PEM private key: {err}"
        ))
    })?;

    let cert = fs::read(cert_path).await.map_err(|err| {
        io::Error::new(
            err.kind(),
            format!("Cannot read the TLS certificate {cert_path}: {err}"),
        )
    })?;
    let chain = CertificateDer::pem_slice_iter(&cert).collect::<Result<Vec<_>, _>>();
    match chain {
        Ok(chain) if !chain.is_empty() => Ok(()),
        Ok(_) => Err(io::Error::other(format!(
            "The TLS certificate {cert_path} contains no certificate"
        ))),
        Err(err) => Err(io::Error::other(format!(
            "The TLS certificate {cert_path} is not a usable PEM chain: {err}"
        ))),
    }
}

async fn check_generate_tls() -> io::Result<()> {
    info!("Generating self-signed TLS certificates");

    let exp = create_end_entity()
        .await
        .map_err(|err| io::Error::other(format!("Cannot generate TLS certificates: {err}")))?;

    task::spawn(renew_self_signed(exp));

    Ok(())
}

/// Keep the self-signed end-entity certificate fresh.
///
/// Nothing in here may panic. It is a long-running task on a node that is already serving, and
/// `panic = "abort"` would take the whole process down with the storage layer mid-flight, at an
/// arbitrary moment hours or days after startup. A certificate that cannot be renewed is a
/// serious but survivable condition: it is reported and retried, and the worst case is that the
/// current certificate expires and TLS handshakes start failing, which is visible without
/// costing the data directory.
async fn renew_self_signed(mut exp: OffsetDateTime) {
    loop {
        let secs = exp.unix_timestamp() - OffsetDateTime::now_utc().unix_timestamp() - 3600;
        if secs > 0 {
            tokio::time::sleep(Duration::from_secs(secs as u64)).await;
        } else {
            warn!(
                "Self-signed end-entity TLS certificate is at or past its renewal point already \
                - renewing now"
            );
            tokio::time::sleep(RENEWAL_FLOOR).await;
        }

        match create_end_entity().await {
            Ok(next) => exp = next,
            Err(err) => {
                error!(
                    "Cannot renew the self-signed TLS certificate: {err}. Retrying in {}s. The \
                    current certificate stays in use until it expires.",
                    RENEWAL_RETRY.as_secs()
                );
                tokio::time::sleep(RENEWAL_RETRY).await;
            }
        }
    }
}

async fn create_end_entity() -> Result<OffsetDateTime, ErrorResponse> {
    let ca = SelfSignedCA::find_or_generate_new().await?;
    let end_entity = ca.create_end_entity().await?;

    fs::create_dir_all(SELF_SIGNED_DIR).await?;
    fs::write(SELF_SIGNED_KEY, end_entity.key_pem).await?;
    fs::write(SELF_SIGNED_CERT, end_entity.cert_chain_pem).await?;

    Ok(end_entity.exp)
}
