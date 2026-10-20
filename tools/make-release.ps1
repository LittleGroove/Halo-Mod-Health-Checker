<#
Makes the release zip: dist\HaloModHealthChecker-<version>.zip, holding a HaloModHealthChecker folder with what a
modder gets (checkmodhealth.cmd, checkmodhealth.ps1, README.md, LICENSE). The version is checkmodhealth.ps1's $Version.
Entries are written with forward slashes (Compress-Archive in Windows PowerShell 5.1 writes backslashes, which some
unzip tools take as part of the file name).

    powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-release.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$repo = Split-Path $PSScriptRoot -Parent
$version = [regex]::Match((Get-Content -LiteralPath (Join-Path $repo 'checkmodhealth.ps1') -Raw), "\`$Version = '([^']+)'").Groups[1].Value
if (-not $version) { throw "checkmodhealth.ps1 has no `$Version line" }
$dist = Join-Path $repo 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist "HaloModHealthChecker-$version.zip"
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in @('checkmodhealth.cmd', 'checkmodhealth.ps1', 'README.md', 'LICENSE')) {
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $repo $name), "HaloModHealthChecker/$name")
    }
} finally {
    $archive.Dispose()
}
Write-Host "Made $zip"
