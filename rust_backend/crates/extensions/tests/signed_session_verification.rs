use mornye_extensions::RuntimeLimits;
use mornye_extensions::environment::ExtensionEnvironment;
use serde_json::{Value, json};

#[test]
fn bootstrap_failure_reaches_the_extension_as_a_retryable_verification_result() {
    let directory = tempfile::tempdir().unwrap();
    let environment = ExtensionEnvironment::new(
        directory.path(),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
    )
    .unwrap();
    let manifest = json!({
        "name":"example.session", "version":"1", "description":"Generic session fixture",
        "type":["download_provider"],
        "permissions":{"storage":true,"network":["127.0.0.1"]},
        "signedSession":{"namespace":"example-session","baseUrl":"https://127.0.0.1"}
    });
    let runtime = environment
        .load(
            &manifest.to_string(),
            r#"registerExtension({
                run() {
                    const response = session.signedFetch('GET', '/track');
                    return response.needsVerification
                        ? {success:false, error_type:'verification_required', response}
                        : {success:false, error_type:'provider_error', response};
                }
            });"#,
            RuntimeLimits::default(),
        )
        .unwrap();
    // The private gateway is denied before any connection. A subsequent call
    // must remain retryable even when no challenge URL could be minted.
    for _ in 0..2 {
        let result = runtime.call("run", "[]", None, 5000).unwrap();
        let result: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(result["error_type"], "verification_required");
        assert_eq!(result["response"]["ok"], false);
        assert_eq!(result["response"]["error"], "VERIFY_REQUIRED");
        assert_eq!(result["response"]["auth_url"], "");
        assert!(
            environment
                .pending_auth("example.session")
                .unwrap()
                .is_none()
        );
    }
    environment.shutdown();
}
