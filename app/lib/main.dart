import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/idle_guard.dart';
import 'core/vault_controller.dart';
import 'pages/home_page.dart';

/// 全局唯一的库控制器（这个应用只开一个库）。
final vault = VaultController();

/// 全局无操作监护：5 分钟没有任何键鼠动作就锁定。
final idleGuard = IdleGuard();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 键盘事件收在进程级，指针事件收在下面的 builder 里——
  // 两处合起来覆盖「打字 / 点击 / 滚动 / 拖动」，包括 push 上去的编辑页。
  HardwareKeyboard.instance.addHandler((event) {
    idleGuard.bump();
    return false; // 不消费：输入照常进输入框
  });
  runApp(const PassbookApp());
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D6F)),
        useMaterial3: true,
      ),
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
