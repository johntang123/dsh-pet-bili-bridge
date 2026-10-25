#Requires -Version 5.1
<#
.SYNOPSIS
  打绿色版发行包（zip，解压即用）。

.DESCRIPTION
  把发行所需的文件复制到 staging，再压成 dist/dsh-pet-bili-bridge-v<version>.zip。
  排除 .git / dist / staging / 本地临时文件。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/build-package.ps1
#>
[CmdletBinding()]
param(
  [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'
$ConfirmPreference = 'None'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutputDir) { $OutputDir = Join-Path $Root 'dist' }

$version = '0.1.0'
$vf = Join-Path $Root 'VERSION'
if (Test-Path -LiteralPath $vf) { $version = (Get-Content -LiteralPath $vf -Raw -Encoding UTF8).Trim() }

$stage = Join-Path $env:TEMP ('dsh-pet-bili-bridge-stage-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$payload = Join-Path $stage 'dsh-pet-bili-bridge'
New-Item -ItemType Directory -Path $payload -Force | Out-Null

$includeFiles = @('README.md', 'LICENSE', 'VERSION', 'CHANGELOG.md', 'install.ps1', 'install.bat', 'uninstall.ps1')
$includeDirs  = @('bin', 'docs', 'tools', 'workbuddy-plugin')

foreach ($f in $includeFiles) {
  $src = Join-Path $Root $f
  if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $payload -Force }
}
foreach ($d in $includeDirs) {
  $src = Join-Path $Root $d
  if (Test-Path -LiteralPath $src) {
    Copy-Item -LiteralPath $src -Destination $payload -Recurse -Force
  }
}

# 清掉可能被带进来的垃圾（只删文件，绝不碰目录）
Get-ChildItem -LiteralPath $payload -Recurse -File -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like '*.bak-*' -or $_.Name -like '*.tmp' -or $_.Name -eq '.DS_Store' } |
  Remove-Item -Force -Confirm:$false -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$zip = Join-Path $OutputDir ("dsh-pet-bili-bridge-v{0}.zip" -f $version)
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

Compress-Archive -Path $payload -DestinationPath $zip -CompressionLevel Optimal -Force

# 校验：列一下包里的条目数
Add-Type -AssemblyName System.IO.Compression.FileSystem
$count = ([System.IO.Compression.ZipFile]::OpenRead($zip)).Entries.Count

# 用 .NET 删 staging，绕开 Remove-Item 的递归确认
try { [System.IO.Directory]::Delete($stage, $true) } catch { }

$size = '{0:N1} KB' -f ((Get-Item -LiteralPath $zip).Length / 1KB)
Write-Host ''
Write-Host "  绿色包已生成：" -ForegroundColor Green
Write-Host "    $zip" -ForegroundColor White
Write-Host "    版本 $version / $count 个条目 / $size" -ForegroundColor DarkGray
Write-Host ''
