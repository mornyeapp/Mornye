[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BundleDir,
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = 'x64',
    [switch]$InspectOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BundleDir = (Resolve-Path $BundleDir).Path
$required = 'mornye.exe', 'flutter_windows.dll', 'mornye_desktop.dll',
    'libmpv-2.dll', 'vcruntime140.dll', 'msvcp140.dll', 'data\app.so', 'ffmpeg\ffmpeg.exe', 'ffmpeg\ffprobe.exe',
    'ffmpeg\LICENSE.txt', 'ffmpeg\SOURCE.txt'
if ($Arch -eq 'x64') {
    $required += 'vcruntime140_1.dll'
}
foreach ($file in $required) {
    if (-not (Test-Path (Join-Path $BundleDir $file) -PathType Leaf)) {
        throw "Missing $file in $BundleDir"
    }
}

$machine = if ($Arch -eq 'arm64') { 0xAA64 } else { 0x8664 }
$binaries = Get-ChildItem $BundleDir -Recurse -File | Where-Object {
    $_.Extension -in '.exe', '.dll'
}
foreach ($binary in $binaries) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($binary.FullName))
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Invalid PE: $($binary.FullName)" }
        $reader.BaseStream.Position = 0x3C
        $offset = $reader.ReadInt32()
        $reader.BaseStream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE: $($binary.FullName)" }
        $actual = $reader.ReadUInt16()
        if ($actual -ne $machine) {
            throw ('Wrong architecture in {0}: expected {1:X4}, got {2:X4}' -f $binary.FullName, $machine, $actual)
        }
    }
    finally {
        $reader.Dispose()
    }
}

$snapshot = [IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $BundleDir 'data\app.so')))
try {
    if ($snapshot.ReadUInt32() -ne 0x464C457F -or $snapshot.ReadByte() -ne 2 -or $snapshot.ReadByte() -ne 1) {
        throw 'The AOT snapshot is not a little-endian ELF64 file.'
    }
    $snapshot.BaseStream.Position = 18
    $snapshotMachine = if ($Arch -eq 'arm64') { 183 } else { 62 }
    if ($snapshot.ReadUInt16() -ne $snapshotMachine) {
        throw "The AOT snapshot has the wrong architecture for $Arch."
    }
}
finally {
    $snapshot.Dispose()
}

if ($InspectOnly) {
    Write-Host "Verified $($binaries.Count) native $Arch binaries and the AOT snapshot without running them."
    return
}

$buildconf = & (Join-Path $BundleDir 'ffmpeg\ffmpeg.exe') -hide_banner -buildconf 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw 'The bundled ffmpeg.exe does not run.' }
if ($buildconf -match '--enable-(gpl|nonfree)') { throw 'The bundled FFmpeg is GPL or nonfree.' }
& (Join-Path $BundleDir 'ffmpeg\ffprobe.exe') -hide_banner -version
if ($LASTEXITCODE -ne 0) { throw 'The bundled ffprobe.exe does not run.' }
Write-Host "Verified $($binaries.Count) native $Arch binaries."
