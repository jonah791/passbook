import 'dart:io';

import 'package:flutter/services.dart';

/// 安装一步：把下载好的产物换成正在运行的这一份。
///
/// 两端机制完全不同，所以只有接口是共用的：
/// · Windows 的 exe 在运行时被锁住 ⇒ 必须**先退出**，由外部脚本等进程消失后覆盖再重启；
/// · Android 不允许应用自替换 ⇒ 只能调系统安装器，让用户点那一次「安装」。
abstract class UpdateInstaller {
  Future<void> apply(File artifact);
}

/// 当前平台能自动安装时返回实现，否则 null（调用方如实报「本平台不支持」）。
UpdateInstaller? installerForPlatform() {
  if (Platform.isWindows) return WindowsZipInstaller();
  if (Platform.isAndroid) return AndroidApkInstaller();
  return null;
}

/// Windows：写一个 PowerShell 脚本到临时目录，脱离父进程启动它，然后由调用方退出应用。
class WindowsZipInstaller implements UpdateInstaller {
  WindowsZipInstaller({Future<Process> Function(List<String>)? launcher})
      : _launcher = launcher;

  final Future<Process> Function(List<String>)? _launcher;

  @override
  Future<void> apply(File artifact) async {
    final exe = File(Platform.resolvedExecutable);
    if (!exe.existsSync()) {
      throw StateError('找不到正在运行的可执行文件：${exe.path}');
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final script = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}passbook-update-$stamp.ps1',
    );
    await script.writeAsString(scriptBody, flush: true);

    final args = <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      '$pid',
      artifact.path,
      exe.parent.path,
      exe.path,
    ];
    final launcher = _launcher ?? _spawnDetached;
    await launcher(args);
  }

  static Future<Process> _spawnDetached(List<String> args) =>
      Process.start('powershell.exe', args, mode: ProcessStartMode.detached);

  /// 脚本本体。五条纪律：
  /// ① 等旧进程真的退出（不等就覆盖被锁的 exe/dll，必失败）
  /// ② 先解压到暂存目录再整体覆盖（边下边解会在半途留下半套程序）
  /// ③ robocopy 的 0–7 都算成功，≥8 才是失败
  /// ④ 失败要留日志——GUI 启动的子进程没有控制台，不打日志就什么都不剩
  /// ⑤ **不用 `Start-Process`**：它复制环境变量时遇到同时存在的 `NO_PROXY` 与 `no_proxy`
  ///    会抛「Item has already been added」，脚本当场死掉（本机实测踩到）。
  ///    调外部程序用 `&` 取 `$LASTEXITCODE`，拉新版本用 .NET 的 `Process.Start`。
  static const String scriptBody = r'''
param(
  [Parameter(Mandatory=$true)][int]$WaitPid,
  [Parameter(Mandatory=$true)][string]$ZipPath,
  [Parameter(Mandatory=$true)][string]$TargetDir,
  [Parameter(Mandatory=$true)][string]$ExePath
)
$ErrorActionPreference = 'Stop'
$log = Join-Path ([System.IO.Path]::GetTempPath()) 'passbook-update.log'
"$(Get-Date -Format o) 开始：pid=$WaitPid zip=$ZipPath target=$TargetDir" | Set-Content -Path $log
for ($i = 0; $i -lt 240; $i++) {
  if (-not (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 250
}
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('passbook-stage-' + [guid]::NewGuid().ToString('N'))
try {
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $stage -Force
  $entries = @(Get-ChildItem -LiteralPath $stage)
  if ($entries.Count -eq 1 -and $entries[0].PSIsContainer -and
      (Test-Path (Join-Path $entries[0].FullName 'passbook.exe'))) {
    $stage = $entries[0].FullName
  }
  & robocopy.exe $stage $TargetDir /E /NFL /NDL /NJH /NJS /R:2 /W:1 | Out-Null
  $rc = $LASTEXITCODE
  "robocopy 退出码 $rc" | Add-Content -Path $log
  if ($rc -ge 8) { throw "robocopy 失败，退出码 $rc" }
} catch {
  $_ | Out-String | Add-Content -Path $log
  exit 1
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
[System.Diagnostics.Process]::Start($ExePath) | Out-Null
"已启动新版本" | Add-Content -Path $log
''';
}

/// Android：把 APK 路径交给原生侧，由它用 FileProvider 拉起系统安装器。
class AndroidApkInstaller implements UpdateInstaller {
  AndroidApkInstaller({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('passbook/updater');

  final MethodChannel _channel;

  @override
  Future<void> apply(File artifact) async {
    final started = await _channel.invokeMethod<bool>('installApk', {
      'path': artifact.path,
    });
    if (started != true) {
      throw StateError('系统没有接过安装请求——去「设置 → 安装未知应用」给 passbook 开权限再试');
    }
  }
}
