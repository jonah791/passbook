// 联调用探针入口（`flutter build apk --target=lib/lan_probe_main.dart`）。
//
// 为什么不直接点界面：跨设备联调要的是**可复现的读数**——谁先说话、谁拿到几条，
// 界面点击给不出机器可读的证据。这个探针跑的是**同一份**核心代码
// （VaultController + LanSync），只是把「点哪里」换成固定顺序，把结果打到
// logcat（`adb logcat -s flutter`）。
//
// 顺序（两段都跑，一次启动就能验两个方向）：
//   ① 本机开端点等对端 → 对端来同步 → 打印合并结果
//   ② 连对端（地址/端口/配对码由 --dart-define 给）→ 拉+合并+推回 → 打印结果
//
// 参数（编译期给）：
//   --dart-define=PROBE_SERVE_PORT=8123
//   --dart-define=PROBE_SERVE_CODE=123456
//   --dart-define=PROBE_PULL_HOST=10.0.2.2
//   --dart-define=PROBE_PULL_PORT=8124
//   --dart-define=PROBE_PULL_CODE=654321
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/sync_lan.dart';
import 'core/vault_controller.dart';

const _servePort = int.fromEnvironment('PROBE_SERVE_PORT', defaultValue: 8123);
const _serveCode = String.fromEnvironment(
  'PROBE_SERVE_CODE',
  defaultValue: '123456',
);
const _pullHost = String.fromEnvironment(
  'PROBE_PULL_HOST',
  defaultValue: '10.0.2.2',
);
const _pullPort = int.fromEnvironment('PROBE_PULL_PORT', defaultValue: 8124);
const _pullCode = String.fromEnvironment(
  'PROBE_PULL_CODE',
  defaultValue: '654321',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('局域网同步探针'))),
    ),
  );
  unawaited(_run());
}

Future<void> _run() async {
  try {
    final vault = VaultController();
    final dir = await getApplicationSupportDirectory();
    final path = '${dir.path}${Platform.pathSeparator}probe.kdbx';
    final fresh = !await File(path).exists();
    final ok = fresh
        ? await vault.createAt(path, 'probe-password')
        : await vault.open(path, 'probe-password');
    if (!ok) {
      _log('FAIL 打不开库 ${vault.lastError}');
      return;
    }
    if (fresh) {
      final entry = vault.addEntry(title: '安卓端建的');
      vault.updateField(entry, 'Notes', '来自 Android 模拟器');
      await vault.flushNow();
    }
    _log('VAULT path=$path fresh=$fresh count=${vault.allEntries.length}');
    for (final e in vault.allEntries) {
      _log('ENTRY ${vault.fieldOf(e, 'Title')}');
    }

    // ① 开端点等对端
    final sync = LanSync(vault);
    final merged = Completer<MergeResult>();
    sync.onMerged = (result) {
      if (!merged.isCompleted) merged.complete(result);
    };
    await sync.start(port: _servePort, code: _serveCode);
    _log('SERVE port=${sync.port} code=${sync.code}');
    try {
      final result = await merged.future.timeout(const Duration(seconds: 120));
      _log(
        'PHASE1 merged added=${result.added} removed=${result.removed} '
        'after=${result.after}',
      );
    } on TimeoutException {
      _log('PHASE1 timeout 没有对端来同步');
    }
    await sync.stop();
    for (final e in vault.allEntries) {
      _log('AFTER1 ${vault.fieldOf(e, 'Title')}');
    }

    // ② 连对端
    final client = LanSync(vault);
    try {
      final result = await client.pullFrom(
        host: _pullHost,
        port: _pullPort,
        code: _pullCode,
      );
      _log(
        'PHASE2 pulled added=${result.added} removed=${result.removed} '
        'after=${result.after}',
      );
    } catch (e) {
      _log('PHASE2 failed $e');
    }
    for (final e in vault.allEntries) {
      _log('AFTER2 ${vault.fieldOf(e, 'Title')}');
    }
    _log('DONE');
  } catch (e, st) {
    _log('FAIL $e\n$st');
  }
}

void _log(String message) {
  // ignore: avoid_print
  print('LANPROBE $message');
}
