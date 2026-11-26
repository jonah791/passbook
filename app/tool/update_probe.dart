import 'dart:io';

import 'package:passbook/core/update/release.dart';
import 'package:passbook/core/update/update_service.dart';

/// 无界面探针：用**应用里同一份代码**走一遍真实链路（GitHub API → 选产物 → 下载 → 校验摘要），
/// 只把读数打到 stdout。
///
/// 存在的理由：自动更新的关键判据都能在不开窗的前提下验完，
/// 而开一次窗就抢一次焦点（这台机器上主人在用）。GUI 留给「看起来对不对」，
/// 读数留给「真的通不通」。
///
/// 跑法：
///   dart run tool/update_probe.dart --version 1.0.0            # 装的就是最新版
///   dart run tool/update_probe.dart --version 0.9.0 --download # 模拟旧版本，真的下一个
///
/// 退出码：0 = 检查成功（有新版或已最新）；1 = 检查失败；2 = 参数错。
Future<void> main(List<String> args) async {
  final version = _flag(args, '--version') ?? '1.0.0';
  final wantDownload = args.contains('--download');

  final service = UpdateService(currentVersion: version);
  stdout.writeln('REPO=$kRepoSlug');
  stdout.writeln('API=$kLatestReleaseUri');
  stdout.writeln('TARGET=${service.target?.artifactName ?? '(不支持本平台)'}');
  stdout.writeln('CURRENT=$version');

  final check = await service.check();
  stdout.writeln('KIND=${check.kind.name}');
  if (check.latest != null) stdout.writeln('LATEST=${check.latest}');
  if (check.release != null) stdout.writeln('TAG=${check.release!.tag}');
  if (check.asset != null) {
    stdout.writeln('ASSET=${check.asset!.name} size=${check.asset!.size}');
    stdout.writeln('ASSET_SHA256_IN_RELEASE=${check.asset!.sha256 ?? '(无，将回落到 SHA256SUMS.txt)'}');
  }
  if (check.message != null) stdout.writeln('NOTE=${check.message}');

  if (check.kind == UpdateCheckKind.failed) exit(1);
  if (!wantDownload || !check.hasUpdate) {
    stdout.writeln('RESULT=ok');
    exit(0);
  }

  stdout.writeln('DOWNLOAD=BEGIN');
  var lastPct = -1;
  try {
    final file = await service.download(
      release: check.release!,
      asset: check.asset!,
      onProgress: (value) {
        final pct = (value * 100).floor();
        if (pct != lastPct && pct % 25 == 0) {
          lastPct = pct;
          stdout.writeln('PROGRESS=$pct%');
        }
      },
    );
    final size = await file.length();
    final sha = await UpdateService.sha256OfFile(file);
    stdout.writeln('DOWNLOAD=OK bytes=$size');
    stdout.writeln('FILE=${file.path}');
    stdout.writeln('SHA256=$sha');
    stdout.writeln('VERIFIED=true');
    await file.delete();
    stdout.writeln('RESULT=ok');
    exit(0);
  } on Object catch (e) {
    stdout.writeln('DOWNLOAD=FAILED $e');
    exit(1);
  }
}

String? _flag(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}
