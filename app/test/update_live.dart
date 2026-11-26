import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/update/release.dart';
import 'package:passbook/core/update/update_service.dart';

/// **真实链路探针**（LIVE）：拿应用里同一份代码去问真的 GitHub 发布，并可选真下一个。
///
/// 为什么不放在 `tool/` 里当脚本跑：本包依赖 Flutter，裸 `dart run` 会在编译
/// `package:flutter` 时崩掉（没有 dart:ui）。而 `flutter test` 的这个文件**不初始化**
/// TestWidgetsFlutterBinding，所以 HTTP 是真的（初始化了的话所有请求会被拦成 400）。
///
/// 又为什么不叫 `*_test.dart`：它要访问公网，不能进默认测试集（CI/离线机器会红）。
/// 显式点名才跑：
///
///   flutter test test/update_live.dart
///   PASSBOOK_PROBE_VERSION=0.9.0 PASSBOOK_PROBE_DOWNLOAD=1 flutter test test/update_live.dart
///
/// 环境变量：
///   PASSBOOK_PROBE_VERSION   假装本机是这个版本（默认 1.0.0），用来走「有新版本」分支
///   PASSBOOK_PROBE_DOWNLOAD  设为 1 时真的下载产物并核对 SHA256
void main() {
  final pretendVersion = Platform.environment['PASSBOOK_PROBE_VERSION'] ?? '1.0.0';
  final wantDownload = Platform.environment['PASSBOOK_PROBE_DOWNLOAD'] == '1';

  test('真实 GitHub 链路：查 → 选产物 → 下载 → 校验', () async {
    final service = UpdateService(currentVersion: pretendVersion);
    stdout.writeln('REPO=$kRepoSlug');
    stdout.writeln('API=$kLatestReleaseUri');
    stdout.writeln('TARGET=${service.target?.artifactName ?? "(不支持本平台)"}');
    stdout.writeln('CURRENT=$pretendVersion');

    final check = await service.check();
    stdout.writeln('KIND=${check.kind.name}');
    if (check.latest != null) stdout.writeln('LATEST=${check.latest}');
    if (check.release != null) stdout.writeln('TAG=${check.release!.tag}');
    if (check.asset != null) {
      stdout.writeln('ASSET=${check.asset!.name} size=${check.asset!.size}');
      stdout.writeln('ASSET_SHA_IN_JSON=${check.asset!.sha256 ?? "(无，回落到 SHA256SUMS.txt)"}');
    }
    if (check.message != null) stdout.writeln('NOTE=${check.message}');

    expect(
      check.kind,
      isNot(UpdateCheckKind.failed),
      reason: '检查失败：${check.message}',
    );

    if (!wantDownload || !check.hasUpdate) {
      stdout.writeln('RESULT=ok（未触发下载）');
      return;
    }

    stdout.writeln('DOWNLOAD=BEGIN');
    var lastPct = -1;
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
    stdout.writeln('SHA256=$sha');
    stdout.writeln('FILE=${file.path}');
    expect(size, check.asset!.size, reason: '下载大小与发布声明不一致');
    await file.delete();
    stdout.writeln('RESULT=ok（下载并校验通过，已删临时文件）');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
