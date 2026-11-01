# Windows code signing

## Code signing policy

Free code signing provided by [SignPath.io](https://signpath.io), certificate
by [SignPath Foundation](https://signpath.org).
As of 2026-10-25, the production certificate is not installed. Releases identify
whether their Windows packages are signed; older unsigned releases remain unsigned.

- Committer and reviewer: [zarzet](https://github.com/zarzet).
- Release signing approver: [zarzet](https://github.com/zarzet).
- The SignPath `CI builds` account can submit requests but cannot approve them.

Release signing requires one manual approval, a trusted GitHub build and origin
verification against `https://github.com/mornyeapp/Mornye.git`. The workflow
signs Mornye's executable and installer, enforcing their product name and
version. Upstream binaries are included without re-signing them as Mornye.

Privacy: SignPath receives release build artifacts and GitHub build metadata
during CI signing. Mornye does not upload users' local audio libraries to
SignPath. Network features in the app contact configured metadata, download,
lyrics, storage and update services. Optional integrations and installed
extensions can contact their own services, whose privacy policies also apply.

## Release integration

The release workflow signs `mornye.exe` before packaging both the portable ZIP
and Inno Setup installer, then signs the installer itself. Both Windows x64 and
ARM64 use the same signing policies and artifact configurations. Third-party
binaries keep their upstream signatures and are not re-signed as Mornye.

## SignPath project

- Organization ID: `0d971895-d8d1-47e7-b64f-eb65df7f5102`
- Project slug: `Mornye`
- Repository: `https://github.com/mornyeapp/Mornye.git`
- Trusted build system: GitHub.com
- Production signing policy: `release-signing`

Create these artifact configurations in the project using the XML files in
this directory, keeping their slugs identical to the values below:

| Slug | XML | Input |
| --- | --- | --- |
| `windows-app-v1` | [windows-app.xml](windows-app.xml) | GitHub artifact ZIP containing the complete Flutter release directory |
| `windows-installer-v1` | [windows-installer.xml](windows-installer.xml) | GitHub artifact ZIP containing exactly one setup EXE |

Both configurations require the `version` parameter. The workflow reads this
value from each EXE's actual ProductVersion resource. A plain PE configuration
cannot process the ZIP archives created by `actions/upload-artifact`.

## GitHub Actions configuration

Configure the following repository variables in `mornyeapp/Mornye`:

| Variable | Value |
| --- | --- |
| `SIGNPATH_ENABLED` | `false` during setup, `true` only when production signing is ready |
| `SIGNPATH_ORGANIZATION_ID` | Organization ID above |
| `SIGNPATH_PROJECT_SLUG` | `Mornye` |
| `SIGNPATH_SIGNING_POLICY_SLUG` | `release-signing` |
| `SIGNPATH_APP_ARTIFACT_CONFIGURATION` | `windows-app-v1` |
| `SIGNPATH_INSTALLER_ARTIFACT_CONFIGURATION` | `windows-installer-v1` |
| `SIGNPATH_CERTIFICATE_THUMBPRINT` | SHA-1 thumbprint of the issued production certificate |

Store the existing SignPath CI user's token as the repository Actions secret
`SIGNPATH_API_TOKEN`. Give that CI user submitter access only to this project's
signing policy. Keep release approval with the interactive maintainer; do not
give the CI user approver or administrator rights. Never commit the token.

Before enabling signing, verify that the production certificate and
`release-signing` policy are valid, both XML configurations are installed,
and the public project code signing policy meets the
[SignPath Foundation requirements](https://signpath.org/terms).
Publish the updated workflow and policy before adding the token and enabling
signing. Update the certificate notice above once the issued certificate is installed.
A certificate showing `CSR PENDING` is not ready for production signing.
This status does not confirm that certificate issuance is progressing automatically.
Do not substitute `test-signing` for a public release.

When enabled, missing settings, rejected signing requests, invalid signatures,
unexpected certificate thumbprints or missing timestamps fail the Windows
build before packages are uploaded. There is no unsigned fallback after a
signing failure. The existing release workflow can omit Windows assets when
their job fails, so also check that both architectures are present in a release.
Signing requests wait up to one hour for manual approval. Approve the app
request first, then the installer request, for each architecture.

## Verification

Local checks:

```sh
actionlint .github/workflows/release.yml
pwsh -NoProfile -File scripts/test_check_windows_signature.ps1
git diff --check
```

The script tests the verification contract with a simulated Windows trust API;
it does not replace testing real signed artifacts on Windows.

After the first signed CI build, download both architectures. Verify the setup
and extracted `mornye.exe` on Windows using
`scripts/check_windows_signature.ps1 -Path <exe> -CertificateThumbprint <thumbprint>`.
Check installer launch, portable launch, and the published SHA-256 checksums.
Code signing identifies the publisher but does not guarantee that SmartScreen
will never display a reputation warning.

Integration reference: [SignPath GitHub Actions](https://docs.signpath.io/trusted-build-systems/github).
