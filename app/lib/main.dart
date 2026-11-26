import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core/idle_guard.dart';
import 'core/vault_controller.dart';
import 'pages/home_page.dart';
import 'theme/app_theme.dart';

/// 全局唯一的库控制器（这个应用只开一个库）。
final vault = VaultController();

/// 全局无操作监护：5 分钟没有任何键鼠动作就锁定。
final idleGuard = IdleGuard();

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // 无窗口自检：只验「这台机器上库能不能建出来」，不开窗、不抢前台。
  // 存在的理由：目录可写性在别的机器上翻过车（受控文件夹访问），
  // 而这件事没法靠单元测试发现——测试环境里 path_provider 是假的。
  if (args.contains('--selftest')) {
    unawaited(_runSelftest());
    return;
  }
  // 键盘事件收在进程级，指针事件收在下面的 builder 里——
  // 两处合起来覆盖「打字 / 点击 / 滚动 / 拖动」，包括 push 上去的编辑页。
  HardwareKeyboard.instance.addHandler((event) {
    idleGuard.bump();
    return false; // 不消费：输入照常进输入框
  });
  runApp(const PassbookApp());
}

/// 结果同时写 stdout 与临时文件（GUI 子系统的 exe 从控制台启动时输出未必留得住）。
Future<void> _runSelftest() async {
  final report = StringBuffer();
  try {
    final candidates = <String>[];
    for (final getter in [
      getApplicationDocumentsDirectory,
      getApplicationSupportDirectory,
    ]) {
      try {
        candidates.add((await getter()).path);
      } catch (e) {
        report.writeln('CANDIDATE_FAIL $e');
      }
    }
    report.writeln('CANDIDATES=${candidates.join(' | ')}');

    // 用独立文件名，绝不碰用户真正的 passbook.kdbx。
    final path = await VaultController.pickWritable(
      candidates,
      fileName: 'passbook-selftest.kdbx',
    );
    report.writeln('PICKED=$path');

    if (path != null) {
      final v = VaultController();
      final created = await v.createAt(path, 'selftest-pw-123');
      report.writeln('CREATE=$created ${v.lastError ?? ''}');
      v.close();

      final reopened = VaultController();
      final opened = await reopened.open(path, 'selftest-pw-123');
      report.writeln('OPEN=$opened ${reopened.lastError ?? ''}');
      reopened.close();

      final file = File(path);
      if (file.existsSync()) file.deleteSync();
      report.writeln('CLEANED=${!file.existsSync()}');
    }
    report.writeln('RESULT=${path != null ? 'PASS' : 'FAIL'}');
  } catch (e) {
    report.writeln('RESULT=FAIL $e');
  }

  final text = report.toString();
  stdout.write(text);
  try {
    File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}passbook-selftest.txt',
    ).writeAsStringSync(text);
  } catch (_) {
    // 报告写不出也别把进程吊在这里。
  }
  exit(0);
}

class PassbookApp extends StatefulWidget {
  const PassbookApp({super.key});

  @override
  State<PassbookApp> createState() => _PassbookAppState();
}

class _PassbookAppState extends State<PassbookApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // 窗口被切走 / 最小化时先把挂起的改动落盘——丢字比被锁更难受。
    // 注意这里**不锁**：切到浏览器把密码复制过来是最常见的用法，锁了反而添乱。
    _lifecycle = AppLifecycleListener(
      onInactive: () => unawaited(vault.flushNow()),
      onPause: () => unawaited(vault.flushNow()),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Passbook',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      // 挂在 Navigator 外层：所有页面的指针事件都会冒泡到这里。
      builder: (context, child) => Listener(
        onPointerDown: (_) => idleGuard.bump(),
        onPointerMove: (_) => idleGuard.bump(),
        onPointerSignal: (_) => idleGuard.bump(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: HomePage(vault: vault, idleGuard: idleGuard),
    );
  }
}
