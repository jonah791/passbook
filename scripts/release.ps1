#Requires -Version 7
<#
.SYNOPSIS
    打一个发布：按 app/pubspec.yaml 的版本号构建两端产物 → 生成 SHA256SUMS.txt → 创建 GitHub Release。

.DESCRIPTION
    版本号的唯一真源是 app/pubspec.yaml 的 `version:`。标签与它不一致时脚本**拒绝执行**——
    客户端的「有没有新版」就是拿 tag 跟这里的版本号比的，两边不一致会让用户永远看到
    「已是最新」或者反复提示同一个版本。

    SHA256SUMS.txt 不是可选项：客户端在摘要缺失时**拒绝自动安装**（密码本不接受
    未经核对的二进制）。所以这个文件必须与产物一起上传。

.EXAMPLE
    pwsh -File scripts/release.ps1 -Tag v1.0.1
    pwsh -File scripts/release.ps1 -Tag v1.0.1 -SkipBuild -Draft
#>
[CmdletBinding()]
param(
    # 发布标签，形如 v1.0.1
    [Parameter(Mandatory = $true)][string]$Tag,
    # 跳过构建，只用 dist/ 里已有的产物（重传、改说明时用）
    [switch]$SkipBuild,
    # 指定 PUB_CACHE（沙箱环境里 pub 缓存目录常常不可写）
    [string]$PubCache = '',
    # 先建草稿，自己看过再发布
    [switch]$Draft
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$app = Join-Path $root 'app'
$dist = Join-Path $root 'dist'
$pubspec = Join-Path $app 'pubspec.yaml'

if (-not (Test-Path $pubspec)) { throw "找不到 $pubspec" }

$versionLine = Select-String -Path $pubspec -Pattern '^version:\s*(\S+)' | Select-Object -First 1
if (-not $versionLine) { throw 'pubspec.yaml 里没有 version: 行' }
$fullVersion = $versionLine.Matches[0].Groups[1].Value      # 1.0.0+1
$version = ($fullVersion -split '\+')[0]                    # 1.0.0

$expectedTag = "v$version"
if ($Tag -ne $expectedTag) {
    throw "标签与版本号不一致：pubspec 是 $version（期望 $expectedTag），传入的是 $Tag。先改 pubspec 再发。"
}

Write-Host "版本 $version（构建号 $fullVersion）· 标签 $Tag" -ForegroundColor Cyan

if (-not $SkipBuild) {
    if ($PubCache) { $env:PUB_CACHE = $PubCache }

    Write-Host '构建 Windows…' -ForegroundColor Cyan
    Push-Location $app
    try {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows 失败，退出码 $LASTEXITCODE" }
    }
    finally { Pop-Location }

    Write-Host '构建 Android…' -ForegroundColor Cyan
    Push-Location $app
    try {
        & flutter build apk --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build apk 失败，退出码 $LASTEXITCODE" }
    }
    finally { Pop-Location }
}

# ── 收集产物 ────────────────────────────────────────────────
if (Test-Path $dist) { Remove-Item -Recurse -Force $dist }
New-Item -ItemType Directory -Path $dist | Out-Null

$winRelease = Join-Path $app 'build\windows\x64\runner\Release'
$winExe = Join-Path $winRelease 'passbook.exe'
$apk = Join-Path $app 'build\app\outputs\flutter-apk\app-release.apk'

if (-not (Test-Path $winExe)) { throw "没有 Windows 产物：$winExe" }
if (-not (Test-Path $apk)) { throw "没有 Android 产物：$apk" }

$winZip = Join-Path $dist 'passbook-windows-x64.zip'
Write-Host '打包 Windows…' -ForegroundColor Cyan
Compress-Archive -Path (Join-Path $winRelease '*') -DestinationPath $winZip -CompressionLevel Optimal

$apkOut = Join-Path $dist 'passbook-android.apk'
Copy-Item $apk $apkOut

# ── 摘要 ────────────────────────────────────────────────────
# 客户端只认这一份：名字对上还要摘要对上才装。
$sums = Join-Path $dist 'SHA256SUMS.txt'
$lines = foreach ($file in @($winZip, $apkOut)) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
    $name = Split-Path -Leaf $file
    $size = (Get-Item -LiteralPath $file).Length
    Write-Host ("  {0}  {1}  ({2:N1} MB)" -f $hash.Substring(0, 12), $name, ($size / 1MB)) -ForegroundColor DarkGray
    "$hash  $name"
}
Set-Content -Path $sums -Value $lines -Encoding utf8NoBOM

# ── 发布 ────────────────────────────────────────────────────
$assets = @($winZip, $apkOut, $sums)
$ghArgs = @('release', 'create', $Tag) + $assets + @('--title', "passbook $Tag", '--generate-notes')
if ($Draft) { $ghArgs += '--draft' }

Write-Host "上传发布 $Tag…" -ForegroundColor Cyan
& gh @ghArgs
if ($LASTEXITCODE -ne 0) { throw "gh release create 失败，退出码 $LASTEXITCODE" }

Write-Host "完成：https://github.com/jonah791/passbook/releases/tag/$Tag" -ForegroundColor Green
Write-Host '提醒：客户端在摘要缺失时会拒绝自动安装，别再手动上传没进 SHA256SUMS.txt 的产物。' -ForegroundColor DarkGray
