import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/biometric.dart';
import 'package:passbook/core/idle_guard.dart';
import 'package:passbook/core/secure_store.dart';
import 'package:passbook/core/vault_controller.dart';
import 'package:passbook/pages/home_page.dart';

/// 锁屏页那一行指纹入口。
///
/// 这里**不打开真库**：每个用例都让指纹验证失败，流程就停在锁屏页，
/// 不会走到「读文件 + 解密」——widget 测试里做真 IO 会被 fake async 卡住。
/// 「取到的密码真能开库」由 biometric_test.dart 的逻辑用例和真机覆盖。
///
/// 连「读最近路径」也不走 SharedPreferences：那条路同样要等平台通道，
/// 在测试的假时钟里不会返回（实测 _boot 卡住、界面永远空白）。
/// 所以换成继承覆盖的假控制器，只回答一个问题：有没有库。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeVault vault;
  late IdleGuard guard;

  setUp(() {
    vault = _FakeVault('/nonexistent/v.kdbx');
    guard = IdleGuard();
  });

  tearDown(() {
    guard.disarm();
    vault.close();
  });

  Future<void> pumpHome(WidgetTester tester, BiometricUnlock? bio) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(vault: vault, idleGuard: guard, biometric: bio),
      ),
    );
    // 让 _boot 里的异步读路径跑完（SharedPreferences 是内存 mock，微任务即可）。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('设备不支持生物识别时，锁屏页不出现指纹入口', (tester) async {
    final platform = _FakePlatform()..supported = false;
    final store = _FakeStore();
    await pumpHome(tester, BiometricUnlock(platform: platform, store: store));

    expect(find.text('输入主密码'), findsOneWidget);
    expect(find.text('用指纹解锁'), findsNothing);
    expect(platform.verifyCalls, 0, reason: '不支持就不该先弹一次验证');
  });

  testWidgets('支持但没开指纹时，也不出现入口', (tester) async {
    final platform = _FakePlatform();
    final store = _FakeStore();
    await pumpHome(tester, BiometricUnlock(platform: platform, store: store));

    expect(find.text('用指纹解锁'), findsNothing);
    expect(platform.verifyCalls, 0, reason: '没开就不该打扰用户');
  });

  testWidgets('开过指纹时，启动会先试一次，并留下指纹按钮', (tester) async {
    final platform = _FakePlatform()..passes = false;
    final store = _FakeStore()..data[BiometricUnlock.keyName] = 'x';
    await pumpHome(tester, BiometricUnlock(platform: platform, store: store));

    // 验证没过 → 仍停在锁屏；按钮在，随时可再点。
    expect(find.text('输入主密码'), findsOneWidget);
    expect(find.text('用指纹解锁'), findsOneWidget);
    expect(platform.verifyCalls, 1, reason: '启动时自动试的那一次');
  });

  testWidgets('点指纹按钮，会再去要一次验证', (tester) async {
    final platform = _FakePlatform()..passes = false;
    final store = _FakeStore()..data[BiometricUnlock.keyName] = 'x';
    await pumpHome(tester, BiometricUnlock(platform: platform, store: store));
    expect(platform.verifyCalls, 1);

    await tester.tap(find.text('用指纹解锁'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(platform.verifyCalls, 2);
  });

  testWidgets('没有接指纹实现时（null），锁屏页与从前一样', (tester) async {
    await pumpHome(tester, null);

    expect(find.text('输入主密码'), findsOneWidget);
    expect(find.text('用指纹解锁'), findsNothing);
  });
}

class _FakePlatform implements BiometricPlatform {
  bool supported = true;
  bool passes = true;
  int verifyCalls = 0;

  @override
  Future<bool> available() async => supported;

  @override
  Future<bool> verify(String reason) async {
    verifyCalls++;
    return passes;
  }
}

class _FakeStore implements SecretStore {
  final Map<String, String> data = <String, String>{};

  @override
  Future<bool> available() async => true;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// 只回答「有没有库」的假控制器：不碰磁盘，也不碰平台通道。
///
/// 本文件所有用例都让指纹验证失败，所以 open 一次也不该被调用——
/// openCalls 就是这条判据本身。
class _FakeVault extends VaultController {
  _FakeVault(this._path);
  final String? _path;
  int openCalls = 0;

  @override
  Future<String?> readLastPath() async => _path;

  @override
  Future<bool> open(String path, String password) async {
    openCalls++;
    return false;
  }

  @override
  void close() {}
}
