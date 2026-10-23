//! The installed extension manifest contract, independent of JavaScript execution.

use crate::storage::valid_extension_id;
use mornye_network::url::UrlParts;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};

trait GoNull {
    fn set_null(&mut self);
}

impl GoNull for String {
    fn set_null(&mut self) {}
}
impl GoNull for bool {
    fn set_null(&mut self) {}
}
impl GoNull for isize {
    fn set_null(&mut self) {}
}
impl<T> GoNull for Vec<T> {
    fn set_null(&mut self) {
        self.clear();
    }
}
impl<T> GoNull for Option<T> {
    fn set_null(&mut self) {
        *self = None;
    }
}
impl GoNull for Map<String, Value> {
    fn set_null(&mut self) {
        self.clear();
    }
}
impl GoNull for Value {
    fn set_null(&mut self) {
        *self = Value::Null;
    }
}

fn is_false(value: &bool) -> bool {
    !value
}
fn is_zero(value: &isize) -> bool {
    *value == 0
}

// Go treats missing and null scalar fields as their zero values. Keeping wire
// names explicit also prevents Rust naming changes from changing mobile JSON.
macro_rules! manifest_struct {
    ($name:ident { $($(#[$attr:meta])* $field:ident: $ty:ty => $wire:literal),* $(,)? }) => {
        #[derive(Clone, Debug, Default, Serialize)]
        pub struct $name {
            $(
                $(#[$attr])*
                #[serde(rename = $wire)]
                pub $field: $ty,
            )*
        }
        impl GoNull for $name { fn set_null(&mut self) {} }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                struct Visitor;
                impl<'de> serde::de::Visitor<'de> for Visitor {
                    type Value = $name;
                    fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                        formatter.write_str("a manifest object")
                    }
                    fn visit_unit<E: serde::de::Error>(self) -> Result<Self::Value, E> {
                        Ok($name::default())
                    }
                    fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                        let mut result = $name::default();
                        while let Some(key) = map.next_key::<String>()? {
                            $(
                                if key.eq_ignore_ascii_case($wire) {
                                    match map.next_value::<Option<$ty>>()? {
                                        Some(value) => result.$field = value,
                                        None => result.$field.set_null(),
                                    }
                                    continue;
                                }
                            )*
                            map.next_value::<serde::de::IgnoredAny>()?;
                        }
                        Ok(result)
                    }
                }
                deserializer.deserialize_any(Visitor)
            }
        }
    };
}

manifest_struct!(ExtensionPermissions {
    network: Option<Vec<String>> => "network",
    storage: bool => "storage",
    file: bool => "file",
    #[serde(skip_serializing_if = "is_false")]
    allow_http: bool => "allowHttp",
});

manifest_struct!(ExtensionSetting {
    key: String => "key", kind: String => "type", label: String => "label",
    #[serde(skip_serializing_if = "String::is_empty")]
    description: String => "description",
    #[serde(skip_serializing_if = "is_false")]
    required: bool => "required",
    #[serde(skip_serializing_if = "is_false")]
    secret: bool => "secret",
    #[serde(skip_serializing_if = "Value::is_null")]
    default: Value => "default",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    options: Vec<String> => "options",
    #[serde(skip_serializing_if = "String::is_empty")]
    action: String => "action",
});

manifest_struct!(QualitySpecificSetting {
    key: String => "key", kind: String => "type", label: String => "label",
    #[serde(skip_serializing_if = "String::is_empty")]
    description: String => "description",
    #[serde(skip_serializing_if = "is_false")]
    required: bool => "required",
    #[serde(skip_serializing_if = "is_false")]
    secret: bool => "secret",
    #[serde(skip_serializing_if = "Value::is_null")]
    default: Value => "default",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    options: Vec<String> => "options",
});

manifest_struct!(QualityOption {
    id: String => "id",
    #[serde(skip_serializing_if = "String::is_empty")]
    kind: String => "kind",
    label: String => "label", description: String => "description",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    settings: Vec<QualitySpecificSetting> => "settings",
});

manifest_struct!(SearchFilter {
    id: String => "id",
    #[serde(skip_serializing_if = "String::is_empty")]
    label: String => "label",
    #[serde(skip_serializing_if = "String::is_empty")]
    icon: String => "icon",
});

manifest_struct!(SearchBehavior {
    enabled: bool => "enabled",
    #[serde(skip_serializing_if = "String::is_empty")]
    placeholder: String => "placeholder",
    #[serde(skip_serializing_if = "is_false")]
    primary: bool => "primary",
    #[serde(skip_serializing_if = "String::is_empty")]
    icon: String => "icon",
    #[serde(skip_serializing_if = "String::is_empty")]
    thumbnail_ratio: String => "thumbnailRatio",
    #[serde(skip_serializing_if = "is_zero")]
    thumbnail_width: isize => "thumbnailWidth",
    #[serde(skip_serializing_if = "is_zero")]
    thumbnail_height: isize => "thumbnailHeight",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    filters: Vec<SearchFilter> => "filters",
});

manifest_struct!(UrlHandler {
    enabled: bool => "enabled",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    patterns: Vec<String> => "patterns",
});

manifest_struct!(TrackMatching {
    custom_matching: bool => "customMatching",
    #[serde(skip_serializing_if = "String::is_empty")]
    strategy: String => "strategy",
    #[serde(skip_serializing_if = "is_zero")]
    duration_tolerance: isize => "durationTolerance",
});

manifest_struct!(PostProcessingHook {
    id: String => "id", name: String => "name",
    #[serde(skip_serializing_if = "String::is_empty")]
    description: String => "description",
    #[serde(skip_serializing_if = "is_false")]
    default_enabled: bool => "defaultEnabled",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    supported_formats: Vec<String> => "supportedFormats",
});

manifest_struct!(PostProcessing {
    enabled: bool => "enabled",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    hooks: Vec<PostProcessingHook> => "hooks",
});

manifest_struct!(HealthCheck {
    id: String => "id",
    #[serde(skip_serializing_if = "String::is_empty")]
    label: String => "label",
    url: String => "url",
    #[serde(skip_serializing_if = "String::is_empty")]
    method: String => "method",
    #[serde(skip_serializing_if = "String::is_empty")]
    service_key: String => "serviceKey",
    #[serde(skip_serializing_if = "is_zero")]
    timeout_ms: isize => "timeoutMs",
    #[serde(skip_serializing_if = "is_zero")]
    cache_ttl_seconds: isize => "cacheTtlSeconds",
    #[serde(skip_serializing_if = "is_false")]
    required: bool => "required",
});

manifest_struct!(SignedSessionEndpoints {
    #[serde(skip_serializing_if = "String::is_empty")]
    bootstrap: String => "bootstrap",
    #[serde(skip_serializing_if = "String::is_empty")]
    challenge: String => "challenge",
    #[serde(skip_serializing_if = "String::is_empty")]
    exchange: String => "exchange",
    #[serde(skip_serializing_if = "String::is_empty")]
    refresh: String => "refresh",
});

manifest_struct!(SignedSession {
    namespace: String => "namespace", base_url: String => "baseUrl",
    #[serde(skip_serializing_if = "String::is_empty")]
    app_version: String => "appVersion",
    #[serde(skip_serializing_if = "String::is_empty")]
    platform: String => "platform",
    #[serde(skip_serializing_if = "String::is_empty")]
    callback_url: String => "callbackUrl",
    #[serde(skip_serializing_if = "String::is_empty")]
    scheme_label: String => "schemeLabel",
    #[serde(skip_serializing_if = "String::is_empty")]
    header_prefix: String => "headerPrefix",
    #[serde(skip_serializing_if = "is_zero")]
    time_window_seconds: isize => "timeWindowSeconds",
    endpoints: SignedSessionEndpoints => "endpoints",
});

manifest_struct!(ExtensionManifest {
    name: String => "name", display_name: String => "displayName",
    version: String => "version", description: String => "description",
    #[serde(skip_serializing_if = "String::is_empty")]
    homepage: String => "homepage",
    #[serde(skip_serializing_if = "String::is_empty")]
    icon: String => "icon",
    types: Vec<String> => "type",
    permissions: ExtensionPermissions => "permissions",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    settings: Vec<ExtensionSetting> => "settings",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    quality_options: Vec<QualityOption> => "qualityOptions",
    #[serde(skip_serializing_if = "String::is_empty")]
    min_app_version: String => "minAppVersion",
    #[serde(skip_serializing_if = "is_false")]
    skip_metadata_enrichment: bool => "skipMetadataEnrichment",
    #[serde(skip_serializing_if = "is_false")]
    skip_lyrics: bool => "skipLyrics",
    #[serde(skip_serializing_if = "is_false")]
    stop_provider_fallback: bool => "stopProviderFallback",
    #[serde(skip_serializing_if = "is_false")]
    skip_built_in_fallback: bool => "skipBuiltInFallback",
    #[serde(skip_serializing_if = "Option::is_none")]
    search_behavior: Option<SearchBehavior> => "searchBehavior",
    #[serde(skip_serializing_if = "Option::is_none")]
    url_handler: Option<UrlHandler> => "urlHandler",
    #[serde(skip_serializing_if = "Option::is_none")]
    track_matching: Option<TrackMatching> => "trackMatching",
    #[serde(skip_serializing_if = "Option::is_none")]
    post_processing: Option<PostProcessing> => "postProcessing",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    service_health: Vec<HealthCheck> => "serviceHealth",
    #[serde(skip_serializing_if = "Option::is_none")]
    signed_session: Option<SignedSession> => "signedSession",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    required_runtime_features: Vec<String> => "requiredRuntimeFeatures",
    #[serde(skip_serializing_if = "Map::is_empty")]
    capabilities: Map<String, Value> => "capabilities",
});

#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    #[error("failed to parse manifest JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("manifest validation error: {field} - {message}")]
    Validation { field: String, message: String },
}

fn invalid(field: impl Into<String>, message: impl Into<String>) -> ManifestError {
    ManifestError::Validation {
        field: field.into(),
        message: message.into(),
    }
}

fn extension_quality_kind(option: &QualityOption, manifest: Option<&ExtensionManifest>) -> String {
    let kind = option.kind.trim().to_ascii_lowercase();
    if matches!(kind.as_str(), "lossless" | "lossy" | "spatial") {
        return kind;
    }

    // Installed manifests from before the kind field was introduced need the
    // same ID/label inference as the Go backend. Descriptions are deliberately
    // excluded because they commonly mention fallback formats.
    let token = option.id.trim().to_ascii_lowercase();
    let text = format!("{token} {}", option.label.to_ascii_lowercase());
    if text.contains("atmos")
        || text.contains("dolby")
        || text.contains("surround")
        || matches!(token.as_str(), "ac4" | "ac-4" | "eac3" | "e-ac-3" | "ec-3")
    {
        return "spatial".to_owned();
    }
    if text.contains("lossless")
        || text.contains("flac")
        || text.contains("alac")
        || text.contains("24-bit")
        || text.contains("16-bit")
        || token == "hi_res"
    {
        return "lossless".to_owned();
    }
    if token == "high"
        || token == "low"
        || text.contains("mp3")
        || text.contains("aac")
        || text.contains("opus")
        || text.contains("vorbis")
    {
        return "lossy".to_owned();
    }
    if matches!(token.as_str(), "best" | "default" | "")
        && let Some(tier) = manifest
            .and_then(|value| value.capabilities.get("downloadFallbackTier"))
            .and_then(Value::as_str)
    {
        match tier.trim().to_ascii_lowercase().as_str() {
            "hi_res" | "lossless" => return "lossless".to_owned(),
            "low_res" => return "lossy".to_owned(),
            _ => {}
        }
    }
    String::new()
}

impl ExtensionManifest {
    pub fn parse(json: &str) -> Result<Self, ManifestError> {
        let manifest: Self = serde_json::from_str(json)?;
        manifest.validate()?;
        Ok(manifest)
    }

    pub fn validate(&self) -> Result<(), ManifestError> {
        if self.name.trim().is_empty() {
            return Err(invalid("name", "name is required"));
        }
        if !valid_extension_id(&self.name) {
            return Err(invalid(
                "name",
                "name must be a lowercase extension ID containing only letters, numbers, '.', '_' or '-'",
            ));
        }
        if self.version.trim().is_empty() {
            return Err(invalid("version", "version is required"));
        }
        if self.description.trim().is_empty() {
            return Err(invalid("description", "description is required"));
        }
        if self.types.is_empty() {
            return Err(invalid("type", "at least one type is required"));
        }
        for kind in &self.types {
            if !matches!(
                kind.as_str(),
                "metadata_provider" | "download_provider" | "lyrics_provider"
            ) {
                return Err(invalid(
                    "type",
                    format!(
                        "invalid extension type: {kind} (must be 'metadata_provider', 'download_provider', or 'lyrics_provider')"
                    ),
                ));
            }
        }
        for (index, setting) in self.settings.iter().enumerate() {
            let failure = if setting.key.trim().is_empty() {
                Some(("key", "setting key is required"))
            } else if setting.kind.is_empty() {
                Some(("type", "setting type is required"))
            } else if setting.kind == "select" && setting.options.is_empty() {
                Some(("options", "select type requires options"))
            } else if setting.kind == "button" && setting.action.is_empty() {
                Some(("action", "button type requires action (JS function name)"))
            } else {
                None
            };
            if let Some((field, message)) = failure {
                return Err(invalid(format!("settings[{index}].{field}"), message));
            }
        }
        for (index, quality) in self.quality_options.iter().enumerate() {
            if !matches!(quality.kind.as_str(), "" | "lossless" | "lossy" | "spatial") {
                return Err(invalid(
                    format!("qualityOptions[{index}].kind"),
                    "quality kind must be lossless, lossy, or spatial",
                ));
            }
        }
        for (index, check) in self.service_health.iter().enumerate() {
            let failure = if check.id.trim().is_empty() {
                Some(("id", "health check id is required"))
            } else if check.url.trim().is_empty() {
                Some(("url", "health check url is required"))
            } else if !matches!(
                check.method.trim().to_uppercase().as_str(),
                "" | "GET" | "HEAD"
            ) {
                Some(("method", "health check method must be GET or HEAD"))
            } else {
                None
            };
            if let Some((field, message)) = failure {
                return Err(invalid(format!("serviceHealth[{index}].{field}"), message));
            }
        }
        if let Some(session) = &self.signed_session {
            if !self.permissions.storage {
                return Err(invalid(
                    "permissions.storage",
                    "signedSession requires storage permission",
                ));
            }
            if session.namespace.trim().is_empty() {
                return Err(invalid("signedSession.namespace", "namespace is required"));
            }
            let base = session.base_url.trim();
            if base.is_empty() {
                return Err(invalid("signedSession.baseUrl", "baseUrl is required"));
            }
            if !base.to_lowercase().starts_with("https://") {
                return Err(invalid("signedSession.baseUrl", "baseUrl must use https"));
            }
            let parsed = UrlParts::parse(base)
                .filter(|url| !url.hostname.is_empty())
                .ok_or_else(|| invalid("signedSession.baseUrl", "baseUrl is invalid"))?;
            if !self.is_domain_allowed(&parsed.hostname) {
                return Err(invalid(
                    "signedSession.baseUrl",
                    "baseUrl host must be listed in permissions.network",
                ));
            }
        }
        if self.has_capability("rawFfmpeg") && !self.permissions.file {
            return Err(invalid(
                "permissions.file",
                "rawFfmpeg capability requires file permission",
            ));
        }
        crate::transfer_policy::validate(&self.capabilities)
            .map_err(|message| invalid("capabilities.downloadTransfer", message))?;
        if let Some(mode) = self.capabilities.get("accountDownloadMode") {
            let valid = mode.as_object().is_some_and(|mode| {
                mode.get("setting")
                    .and_then(Value::as_str)
                    .is_some_and(|key| !key.is_empty() && !key.starts_with('_') && key.len() <= 64)
                    && mode
                        .get("value")
                        .and_then(Value::as_str)
                        .is_some_and(|value| !value.is_empty() && value.len() <= 64)
            });
            if !valid {
                return Err(invalid(
                    "capabilities.accountDownloadMode",
                    "expected a setting and value",
                ));
            }
        }
        if let Some(timeout) = self.capabilities.get("actionTimeoutSeconds")
            && !timeout
                .as_u64()
                .is_some_and(|seconds| (1..=120).contains(&seconds))
        {
            return Err(invalid(
                "capabilities.actionTimeoutSeconds",
                "expected 1 to 120 seconds",
            ));
        }
        Ok(())
    }

    pub fn has_capability(&self, name: &str) -> bool {
        self.capabilities.get(name) == Some(&Value::Bool(true))
    }

    pub(crate) fn account_download_enabled(&self, settings: &Map<String, Value>) -> bool {
        self.capabilities
            .get("accountDownloadMode")
            .is_some_and(|mode| {
                let Some(setting) = mode["setting"].as_str() else {
                    return false;
                };
                let Some(value) = mode["value"].as_str() else {
                    return false;
                };
                settings.get(setting).and_then(Value::as_str) == Some(value)
            })
    }

    pub(crate) fn action_timeout_ms(&self, default: u64) -> u64 {
        self.capabilities
            .get("actionTimeoutSeconds")
            .and_then(Value::as_u64)
            .map_or(default, |seconds| seconds.clamp(1, 120) * 1000)
    }

    pub fn find_quality(&self, requested: &str) -> Option<&QualityOption> {
        let requested = requested.trim();
        if requested.is_empty() {
            return None;
        }
        self.quality_options
            .iter()
            .find(|option| option.id.trim().eq_ignore_ascii_case(requested))
    }

    pub fn resolve_download_quality(
        &self,
        requested: &str,
        source: Option<&ExtensionManifest>,
    ) -> Result<String, String> {
        let requested = requested.trim();
        if self.quality_options.is_empty() {
            return Ok(requested.to_owned());
        }

        let source_quality = source.and_then(|manifest| manifest.find_quality(requested));
        let source_option = source_quality.cloned().unwrap_or_else(|| QualityOption {
            id: requested.to_owned(),
            ..QualityOption::default()
        });
        let kind = extension_quality_kind(&source_option, source);

        if let Some(exact) = self.find_quality(requested) {
            let target_kind = extension_quality_kind(exact, Some(self));
            if source.is_some_and(|manifest| manifest.name == self.name)
                || (!kind.is_empty() && kind == target_kind)
                || (kind.is_empty() && target_kind != "spatial")
            {
                return Ok(exact.id.trim().to_owned());
            }
        }

        let kind = if kind.is_empty() {
            "lossless"
        } else {
            kind.as_str()
        };
        let allowed_kinds: Vec<&str> = if matches!(kind, "spatial" | "lossy") {
            vec![kind, "lossless"]
        } else {
            vec![kind]
        };
        for allowed in allowed_kinds {
            if let Some(candidate) = self.quality_options.iter().find(|candidate| {
                let id = candidate.id.trim();
                !id.is_empty() && extension_quality_kind(candidate, Some(self)) == *allowed
            }) {
                return Ok(candidate.id.trim().to_owned());
            }
        }
        Err(format!(
            "provider {} has no compatible {} quality for {:?}",
            self.name, kind, requested
        ))
    }

    pub fn has_type(&self, kind: &str) -> bool {
        self.types.iter().any(|value| value == kind)
    }
    pub fn stops_provider_fallback(&self) -> bool {
        self.stop_provider_fallback || self.skip_built_in_fallback
    }

    pub fn is_domain_allowed(&self, domain: &str) -> bool {
        let domain = domain.trim().to_lowercase();
        self.permissions
            .network
            .as_deref()
            .unwrap_or_default()
            .iter()
            .any(|allowed| {
                let allowed = allowed.trim().to_lowercase();
                allowed == "*"
                    || allowed == domain
                    || (allowed.starts_with("*.") && domain.ends_with(&allowed[1..]))
            })
    }

    pub fn matches_url(&self, url: &str) -> bool {
        let Some(handler) = &self.url_handler else {
            return false;
        };
        if !handler.enabled {
            return false;
        }
        let url = url.trim().to_lowercase();
        let parsed = UrlParts::parse(&url);
        handler.patterns.iter().any(|pattern| {
            let pattern = pattern.trim().to_lowercase();
            if pattern.is_empty() {
                return false;
            }
            if !pattern.contains('/') && pattern.ends_with(':') {
                return url.starts_with(&pattern);
            }
            let Some(parsed) = parsed.as_ref().filter(|url| !url.hostname.is_empty()) else {
                return false;
            };
            let pattern = pattern
                .split_once("://")
                .map_or(pattern.as_str(), |(_, rest)| rest);
            let (host, path) = pattern.split_once('/').unwrap_or((pattern, ""));
            !host.is_empty()
                && (parsed.hostname == host || parsed.hostname.ends_with(&format!(".{host}")))
                && (path.is_empty() || parsed.path.starts_with(format!("/{path}").as_bytes()))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(network: Value) -> Result<ExtensionManifest, ManifestError> {
        ExtensionManifest::parse(
            &serde_json::json!({
                "name":"generic-media","version":"1.0.0","description":"Generic fixture",
                "type":["download_provider"],"permissions":{"storage":true,"network":network},
                "signedSession":{"namespace":"generic","baseUrl":"https://accounts.example.test"}
            })
            .to_string(),
        )
    }

    #[test]
    fn any_domain_wildcard_covers_listed_hosts() {
        let any = manifest(serde_json::json!(["*"])).unwrap();
        assert!(any.is_domain_allowed("accounts.example.test"));
        assert!(any.is_domain_allowed("192.168.178.20"));
        let scoped = manifest(serde_json::json!(["*.example.test"])).unwrap();
        assert!(!scoped.is_domain_allowed("example.org"));
        assert!(manifest(serde_json::json!(["example.org"])).is_err());
    }
}
