use super::{RepositoryError, error};
use mornye_network::url::UrlParts;

#[derive(Debug, PartialEq, Eq)]
pub enum RegistryLocation {
    Direct(String),
    GitHub { owner: String, repository: String },
}

pub fn registry_location(input: &str) -> Result<RegistryLocation, RepositoryError> {
    let input = input.trim();
    if input.is_empty() {
        return Err(error("registry URL is empty"));
    }
    if input.contains("raw.githubusercontent.com") {
        return Ok(RegistryLocation::Direct(input.into()));
    }
    let Some(path) = input
        .strip_prefix("https://github.com/")
        .or_else(|| input.strip_prefix("http://github.com/"))
    else {
        return Ok(RegistryLocation::Direct(input.into()));
    };
    let mut parts = path.splitn(3, '/');
    let owner = parts.next().unwrap_or("");
    let repository = parts.next().unwrap_or("");
    if owner.is_empty() || repository.is_empty() {
        return Err(error(
            "invalid GitHub URL: expected github.com/<owner>/<repo>",
        ));
    }
    Ok(RegistryLocation::GitHub {
        owner: owner.into(),
        repository: repository.strip_suffix(".git").unwrap_or(repository).into(),
    })
}

/// The label a configured source shows: the registry's own `name` when it
/// has one, else `<owner>/<repo>` for GitHub, else host plus path without a
/// trailing `/registry.json`.
pub fn source_name(registry_url: &str, registry_name: &str) -> String {
    let name = registry_name.trim();
    if !name.is_empty() {
        return name.into();
    }
    let url = registry_url.trim();
    for prefix in ["https://raw.githubusercontent.com/", "https://github.com/"] {
        let Some(path) = url.strip_prefix(prefix) else {
            continue;
        };
        let mut parts = path.split(['/', '?', '#']);
        let owner = parts.next().unwrap_or("");
        let repository = parts.next().unwrap_or("");
        let repository = repository.strip_suffix(".git").unwrap_or(repository);
        if !owner.is_empty() && !repository.is_empty() {
            return format!("{owner}/{repository}");
        }
    }
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let rest = rest.split(['?', '#']).next().unwrap_or("");
    let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
    let host = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    let path = format!("/{path}");
    let path = path.strip_suffix("/registry.json").unwrap_or(&path);
    format!("{host}{}", path.trim_end_matches('/'))
}

pub fn require_https(input: &str, context: &str) -> Result<(), RepositoryError> {
    if input.is_empty() {
        return Err(error(format!("{context} URL is empty")));
    }
    let url = UrlParts::parse(input)
        .filter(|url| !url.hostname.is_empty())
        .ok_or_else(|| error(format!("{context} URL is invalid: {input}")))?;
    if url.scheme != "https" {
        return Err(error(format!("{context} URL must use https: {input}")));
    }
    Ok(())
}
