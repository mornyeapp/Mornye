[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$CertificateThumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Path = (Resolve-Path -LiteralPath $Path).Path
$expected = $CertificateThumbprint.Replace(' ', '').ToUpperInvariant()
if ($expected -notmatch '^[0-9A-F]{40}$') {
    throw 'Expected the SHA-1 thumbprint of the SignPath release certificate.'
}

$signature = Get-AuthenticodeSignature -LiteralPath $Path
if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
    throw "Invalid Authenticode signature on ${Path}: $($signature.Status)"
}
if ($signature.SignerCertificate.Thumbprint -ne $expected) {
    throw "Unexpected signing certificate on $Path"
}
if ($null -eq $signature.TimeStamperCertificate) {
    throw "Missing Authenticode timestamp on $Path"
}
Write-Host "Verified trusted, timestamped SignPath signature: $Path"
