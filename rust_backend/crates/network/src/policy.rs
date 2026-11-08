//! Permission checks happen before dispatch and again on every resolved address.

use crate::url::UrlParts;
use std::net::IpAddr;

/// A host the user typed into an extension setting marked `grantsNetwork`.
/// It extends that extension's allowlist; private-network checks still apply.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GrantedOrigin {
    pub scheme: String,
    pub host: String,
}

impl GrantedOrigin {
    /// Accepts an `http` or `https` URL with a host and no credentials.
    pub fn parse(input: &str) -> Option<Self> {
        let url = UrlParts::parse(input.trim())?;
        if !matches!(url.scheme.as_str(), "http" | "https")
            || url.has_credentials
            || url.hostname.is_empty()
        {
            return None;
        }
        Some(Self {
            scheme: url.scheme,
            host: url.hostname.trim().to_lowercase(),
        })
    }
}

#[derive(Clone, Debug, Default)]
pub struct NetworkPermissions {
    pub domains: Vec<String>,
    pub allow_http: bool,
}

impl NetworkPermissions {
    /// `*` admits every host; scheme and private-network checks still apply.
    pub fn allows_domain(&self, domain: &str) -> bool {
        let domain = domain.trim().to_lowercase();
        self.domains.iter().any(|allowed| {
            let allowed = allowed.trim().to_lowercase();
            allowed == "*"
                || allowed == domain
                || allowed.strip_prefix("*.").is_some_and(|suffix| {
                    domain.len() > suffix.len() + 1 && domain.ends_with(&format!(".{suffix}"))
                })
        })
    }

    pub fn validate(
        &self,
        input: &str,
        allow_private: bool,
        redirect: bool,
    ) -> Result<UrlParts, String> {
        self.validate_with_grants(input, allow_private, redirect, &[])
    }

    /// Like `validate`, also admitting hosts the user granted in settings.
    /// A grant made with `http://` allows plain HTTP for that host only.
    pub fn validate_with_grants(
        &self,
        input: &str,
        allow_private: bool,
        redirect: bool,
        grants: &[GrantedOrigin],
    ) -> Result<UrlParts, String> {
        let url = UrlParts::parse(input).ok_or_else(|| "invalid URL".to_owned())?;
        if url.scheme.is_empty() && !redirect {
            return Err("invalid URL: scheme is required".to_owned());
        }
        let host = url.hostname.trim().to_lowercase();
        let granted = grants.iter().any(|grant| grant.host == host);
        let granted_http = grants
            .iter()
            .any(|grant| grant.host == host && grant.scheme == "http");
        if url.scheme != "https" && !(url.scheme == "http" && (self.allow_http || granted_http)) {
            return Err(if redirect {
                "redirect blocked: only https is allowed"
            } else {
                "network access denied: only https is allowed"
            }
            .to_owned());
        }
        if url.has_credentials {
            return Err("invalid URL: embedded credentials are not allowed".to_owned());
        }
        if url.hostname.is_empty() {
            return Err(if redirect {
                "redirect blocked: hostname is required"
            } else {
                "invalid URL: hostname is required"
            }
            .to_owned());
        }
        if !redirect && !allow_private && private_literal_or_local(&url.hostname) {
            return Err(format!(
                "network access denied: private/local network '{}' not allowed",
                url.hostname
            ));
        }
        if !granted && !self.allows_domain(&url.hostname) {
            return Err(format!(
                "{}: domain '{}' not in allowed list",
                if redirect {
                    "redirect blocked"
                } else {
                    "network access denied"
                },
                url.hostname
            ));
        }
        if redirect && !allow_private && private_literal_or_local(&url.hostname) {
            return Err("redirect blocked: private/local network access denied".to_owned());
        }
        // Hyper skips the resolver for literal addresses. Check the actual URI
        // too, including any host canonicalization performed by IDNA parsing.
        let uri = url.request_uri()?;
        if !allow_private && uri.host().is_some_and(private_literal_or_local) {
            return Err(format!(
                "network access denied: private/local network '{}' not allowed",
                url.hostname
            ));
        }
        Ok(url)
    }
}

pub fn private_literal_or_local(host: &str) -> bool {
    let host = host
        .trim()
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_lowercase();
    host == "localhost"
        || host.ends_with(".local")
        || host
            .split('%')
            .next()
            .and_then(|address| address.parse().ok())
            .is_some_and(is_private_ip)
}

/// Matches Go net.IP's private/global-unicast checks, including mapped IPv4.
/// TEST-NET, CGNAT and reserved unicast ranges are not silently reclassified.
pub fn is_private_ip(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(ip) => {
            ip.is_loopback()
                || ip.is_private()
                || ip.is_link_local()
                || ip.is_multicast()
                || ip.is_unspecified()
                || ip.is_broadcast()
        }
        IpAddr::V6(ip) => {
            if let Some(ip) = ip.to_ipv4_mapped() {
                return is_private_ip(IpAddr::V4(ip));
            }
            ip.is_loopback()
                || ip.is_unique_local()
                || ip.is_unicast_link_local()
                || ip.is_multicast()
                || ip.is_unspecified()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn private_ranges_match_go_and_mapped_addresses() {
        for address in [
            "127.0.0.1",
            "10.2.3.4",
            "169.254.1.1",
            "172.31.0.1",
            "192.168.1.1",
            "224.0.0.1",
            "255.255.255.255",
            "0.0.0.0",
            "::",
            "::1",
            "fc00::1",
            "fe80::1",
            "ff02::1",
            "::ffff:127.0.0.1",
        ] {
            assert!(is_private_ip(address.parse().unwrap()), "{address}");
        }
        for address in [
            "1.1.1.1",
            "100.64.0.1",
            "192.0.2.1",
            "198.51.100.1",
            "203.0.113.1",
            "240.0.0.1",
            "0.0.0.1",
            "2001:db8::1",
            "::127.0.0.1",
            "::ffff:192.0.2.1",
        ] {
            assert!(!is_private_ip(address.parse().unwrap()), "{address}");
        }
    }

    #[test]
    fn deny_by_default_and_validate_redirects_and_actual_literal() {
        let mut permissions = NetworkPermissions::default();
        assert!(
            permissions
                .validate("https://api.example.test/x", false, false)
                .is_err()
        );
        permissions.domains = vec!["*.example.test".into(), "127.1".into(), "localhost".into()];
        assert!(
            permissions
                .validate("https://api.example.test/x/../y", false, false)
                .is_ok()
        );
        assert!(!permissions.allows_domain("example.test"));
        assert!(!permissions.allows_domain("badexample.test"));
        assert!(
            permissions
                .validate("https://127.1/x", false, false)
                .unwrap_err()
                .contains("private/local")
        );
        assert!(
            permissions
                .validate("https://user@api.example.test", false, false)
                .is_err()
        );
        assert_eq!(
            permissions
                .validate("http://api.example.test", false, true)
                .unwrap_err(),
            "redirect blocked: only https is allowed"
        );
        assert!(
            permissions
                .validate("https://localhost", true, false)
                .is_ok()
        );
    }

    #[test]
    fn any_domain_wildcard_keeps_scheme_and_private_checks() {
        let mut permissions = NetworkPermissions {
            domains: vec![" * ".into()],
            allow_http: false,
        };
        for input in [
            "https://media.example.test/x",
            "https://example.org",
            "https://203.0.113.5:8920/x",
        ] {
            assert!(permissions.validate(input, false, false).is_ok(), "{input}");
        }
        assert!(
            permissions
                .validate("https://192.168.178.20:8920", false, false)
                .unwrap_err()
                .contains("private/local")
        );
        assert!(
            permissions
                .validate("https://server.local", false, false)
                .unwrap_err()
                .contains("private/local")
        );
        assert_eq!(
            permissions
                .validate("http://192.168.178.20:8096", true, false)
                .unwrap_err(),
            "network access denied: only https is allowed"
        );
        permissions.allow_http = true;
        for input in [
            "http://192.168.178.20:8096/System/Info",
            "http://server.local:8096",
            "http://media.example.test",
        ] {
            assert!(permissions.validate(input, true, false).is_ok(), "{input}");
        }
        assert!(
            permissions
                .validate("http://192.168.178.20:8096", false, false)
                .is_err()
        );
        assert!(
            permissions
                .validate("http://user:secret@192.168.178.20", true, false)
                .is_err()
        );
    }

    #[test]
    fn granted_hosts_extend_the_allowlist_without_lifting_other_checks() {
        let permissions = NetworkPermissions {
            domains: vec!["api.example.test".into()],
            allow_http: false,
        };
        let grants = [
            GrantedOrigin::parse("https://Self.Example.org/api").unwrap(),
            GrantedOrigin::parse("http://192.168.1.20:8000").unwrap(),
        ];
        let check = |input: &str, allow_private: bool| {
            permissions.validate_with_grants(input, allow_private, false, &grants)
        };
        assert!(check("https://self.example.org/track", false).is_ok());
        assert!(check("https://api.example.test/x", false).is_ok());
        assert!(
            permissions
                .validate("https://self.example.org/track", false, false)
                .is_err()
        );
        // An https grant does not open plain http.
        assert!(check("http://self.example.org/track", false).is_err());
        assert!(check("https://other.example.org", false).is_err());
        // An http grant opens http for that host only; private hosts still need the app toggle.
        assert!(check("http://192.168.1.20:8000/x", false).is_err());
        assert!(check("http://192.168.1.20:8000/x", true).is_ok());
        assert!(check("http://192.168.1.21:8000/x", true).is_err());
        assert!(GrantedOrigin::parse("ftp://example.org").is_none());
        assert!(GrantedOrigin::parse("https://user:pw@example.org").is_none());
    }
}
