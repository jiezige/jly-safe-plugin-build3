param(
  [string]$IpaPath = "E:\minimax\1\leyuan\pj\10\o_1jnk690m4gjo1nsd1tai1o441q489.ipa",
  [string]$DylibPath = "E:\minimax\1\leyuan\pj\10\ios-plugin\build\cike.dylib",
  [string]$OutputPath = "E:\minimax\1\leyuan\pj\10\o_1jnk690m4gjo1nsd1tai1o441q489_apk_features_unsigned.ipa"
)

$ErrorActionPreference = "Stop"

if (!(Test-Path -LiteralPath $IpaPath)) {
  throw "IPA not found: $IpaPath"
}

if (!(Test-Path -LiteralPath $DylibPath)) {
  throw "Dylib not found: $DylibPath"
}

$root = Split-Path -Parent $OutputPath
if (!(Test-Path -LiteralPath $root)) {
  New-Item -ItemType Directory -Path $root | Out-Null
}

$workDir = Join-Path $root "_ipa_repack_unsigned"
if (Test-Path -LiteralPath $workDir) {
  Remove-Item -LiteralPath $workDir -Recurse -Force
}
New-Item -ItemType Directory -Path $workDir | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($IpaPath, $workDir)

$payload = Join-Path $workDir "Payload"
$app = Get-ChildItem -LiteralPath $payload -Directory | Select-Object -First 1
if (!$app) {
  throw "Payload app directory not found"
}

$targetDylib = Join-Path $app.FullName "cike.dylib"
Copy-Item -LiteralPath $DylibPath -Destination $targetDylib -Force

$codeSignature = Join-Path $app.FullName "_CodeSignature"
if (Test-Path -LiteralPath $codeSignature) {
  Remove-Item -LiteralPath $codeSignature -Recurse -Force
}

Get-ChildItem -LiteralPath $app.FullName -Recurse -Force -Filter "*.dSYM" | Remove-Item -Recurse -Force

if (Test-Path -LiteralPath $OutputPath) {
  Remove-Item -LiteralPath $OutputPath -Force
}

$zipStream = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew)
$archive = New-Object IO.Compression.ZipArchive($zipStream, [IO.Compression.ZipArchiveMode]::Create)
try {
  $basePath = (Resolve-Path -LiteralPath $workDir).Path.TrimEnd([IO.Path]::DirectorySeparatorChar)
  Get-ChildItem -LiteralPath $workDir -Recurse -File -Force | ForEach-Object {
    $relative = $_.FullName.Substring($basePath.Length + 1)
    $entryName = $relative.Replace([IO.Path]::DirectorySeparatorChar, "/")
    $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
    $entryStream = $entry.Open()
    $fileStream = [IO.File]::OpenRead($_.FullName)
    try {
      $fileStream.CopyTo($entryStream)
    } finally {
      $fileStream.Dispose()
      $entryStream.Dispose()
    }
  }
} finally {
  $archive.Dispose()
  $zipStream.Dispose()
}

Write-Host "Unsigned IPA written to: $OutputPath"
