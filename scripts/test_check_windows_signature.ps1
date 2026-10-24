[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot 'check_windows_signature.ps1'
$fixtureDir = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $fixtureDir | Out-Null
$fixture = Join-Path $fixtureDir 'Mornye [signature test].exe'
[IO.File]::WriteAllText($fixture, 'Signature API fixture, not an executable.')
$thumbprint = '0123456789ABCDEF0123456789ABCDEF01234567'
$signatureState = @{ Result = $null }

# The Windows trust API is injected so the rejection paths also run on macOS.
function Get-AuthenticodeSignature {
    param([string]$LiteralPath)
    if ($LiteralPath -ne $fixture) { throw 'Signature checked the wrong file.' }
    return $signatureState.Result
}

function Assert-Rejected {
    param([string]$ExpectedMessage, [string]$ExpectedThumbprint = $thumbprint)
    $message = ''
    try {
        & $checker -Path $fixture -CertificateThumbprint $ExpectedThumbprint
    }
    catch {
        $message = $_.Exception.Message
    }
    if (-not $message.Contains($ExpectedMessage)) {
        throw "Expected rejection containing '$ExpectedMessage', got '$message'."
    }
}

try {
    $signatureState.Result = [pscustomobject]@{
        Status = 'Valid'
        SignerCertificate = [pscustomobject]@{ Thumbprint = $thumbprint }
        TimeStamperCertificate = [pscustomobject]@{ Subject = 'Timestamp authority' }
    }
    & $checker -Path $fixture -CertificateThumbprint $thumbprint.ToLowerInvariant()
    Assert-Rejected -ExpectedMessage 'SHA-1 thumbprint' -ExpectedThumbprint 'not-a-thumbprint'
    Assert-Rejected -ExpectedMessage 'Unexpected signing certificate' -ExpectedThumbprint ('A' * 40)

    foreach ($status in 'NotSigned', 'HashMismatch', 'NotTrusted', 'UnknownError') {
        $signatureState.Result.Status = $status
        Assert-Rejected -ExpectedMessage "Invalid Authenticode signature on ${fixture}: $status"
    }
    $signatureState.Result.Status = 'Valid'
    $signatureState.Result.TimeStamperCertificate = $null
    Assert-Rejected -ExpectedMessage 'Missing Authenticode timestamp'
    $signatureState.Result.SignerCertificate = $null
    Assert-Rejected -ExpectedMessage 'Invalid Authenticode signature'
    Write-Host 'Signature verification contract passed: valid signature and eight rejection cases.'
}
finally {
    Remove-Item -LiteralPath $fixtureDir -Recurse -Force
}
