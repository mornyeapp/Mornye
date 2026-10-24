//! The server identity (contract section 2): a self-signed ECDSA P-256
//! certificate for `mornye.local`, valid 20 years, generated on first start
//! into `cert.pem` and `key.pem` and reused afterwards. Phones pin its
//! fingerprint, the lowercase hex SHA-256 of the DER certificate.

use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::sync::Arc;

const CERT_FILE: &str = "cert.pem";
const KEY_FILE: &str = "key.pem";
const SUBJECT_NAME: &str = "mornye.local";
const VALIDITY_DAYS: i64 = 20 * 365 + 5;

/// The loaded certificate, its TLS configuration and fingerprint.
pub(crate) struct Identity {
    pub(crate) fingerprint: String,
    pub(crate) config: Arc<rustls::ServerConfig>,
}

/// Lowercase hex SHA-256 of a DER certificate.
pub(crate) fn fingerprint(der: &[u8]) -> String {
    crate::auth::hex(&Sha256::digest(der))
}

/// Loads the identity from `dir`, generating a new one when either file is
/// missing or unusable.
pub(crate) fn load_or_create(dir: &Path) -> Result<Identity, String> {
    if let Some(identity) = load(dir) {
        return Ok(identity);
    }
    let (cert_pem, key_pem) = generate()?;
    // Key first: a certificate without its key is never left behind.
    crate::store::write_private(&dir.join(KEY_FILE), key_pem.as_bytes())?;
    crate::store::write_private(&dir.join(CERT_FILE), cert_pem.as_bytes())?;
    load(dir).ok_or_else(|| "The new Mornye Link certificate could not be loaded".to_owned())
}

fn load(dir: &Path) -> Option<Identity> {
    let cert_pem = std::fs::read(dir.join(CERT_FILE)).ok()?;
    let key_pem = std::fs::read(dir.join(KEY_FILE)).ok()?;
    let cert = CertificateDer::from_pem_slice(&cert_pem).ok()?;
    let key = PrivateKeyDer::from_pem_slice(&key_pem).ok()?;
    let fingerprint = fingerprint(&cert);
    let config = server_config(cert, key).ok()?;
    Some(Identity {
        fingerprint,
        config,
    })
}

fn generate() -> Result<(String, String), String> {
    let fail = |error: rcgen::Error| format!("Cannot create the Mornye Link certificate: {error}");
    let key = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256).map_err(fail)?;
    let mut params = rcgen::CertificateParams::new(vec![SUBJECT_NAME.to_owned()]).map_err(fail)?;
    params
        .distinguished_name
        .push(rcgen::DnType::CommonName, SUBJECT_NAME);
    let now = time::OffsetDateTime::now_utc();
    // A day of slack for phones whose clock runs behind.
    params.not_before = now - time::Duration::days(1);
    params.not_after = now + time::Duration::days(VALIDITY_DAYS);
    let cert = params.self_signed(&key).map_err(fail)?;
    Ok((cert.pem(), key.serialize_pem()))
}

/// TLS 1.2 and 1.3 with the ring provider, HTTP/1.1 only.
fn server_config(
    cert: CertificateDer<'static>,
    key: PrivateKeyDer<'static>,
) -> Result<Arc<rustls::ServerConfig>, String> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut config = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|error| error.to_string())?
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .map_err(|error| error.to_string())?;
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(Arc::new(config))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generates_once_and_reloads_the_same_identity() {
        let dir = tempfile::tempdir().unwrap();
        let first = load_or_create(dir.path()).unwrap();
        assert_eq!(first.fingerprint.len(), 64);
        assert!(
            first
                .fingerprint
                .chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
        );
        let pem = std::fs::read(dir.path().join(CERT_FILE)).unwrap();
        let der = CertificateDer::from_pem_slice(&pem).unwrap();
        assert_eq!(fingerprint(&der), first.fingerprint);
        let second = load_or_create(dir.path()).unwrap();
        assert_eq!(second.fingerprint, first.fingerprint);
    }

    #[test]
    fn replaces_a_broken_key() {
        let dir = tempfile::tempdir().unwrap();
        let first = load_or_create(dir.path()).unwrap();
        std::fs::write(dir.path().join(KEY_FILE), b"broken").unwrap();
        let second = load_or_create(dir.path()).unwrap();
        assert_ne!(second.fingerprint, first.fingerprint);
    }
}
