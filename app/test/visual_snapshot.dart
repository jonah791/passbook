import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/idle_guard.dart';
import 'package:passbook/core/vault_controller.dart';
import 'package:passbook/pages/home_page.dart';
import 'package:passbook/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 视觉快照：把三屏渲染成 PNG，供人眼复核。
///
/// 为什么不放进常规测试：golden 比对依赖本机字体，换机器必红；而且它验的是
/// 「好不好看」，判据在眼睛，不在断言。跑法：
///
/// ```
/// flutter test test/visual_snapshot.dart --update-goldens
/// ```
///
/// 生成物在 `test/goldens/`，看完再提交。
///
/// ⚠ 已知装置缺陷：列表页（02/04）图上每行右侧的钥匙图标渲染成豆腐块——本机
/// 图标字体缺该字形，是**装置侧**的问题。真机是否正常**未验**（没起窗口核过），
/// 别据此下产品结论。
void main() {
  late String vaultPath;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _loadSystemFonts();

    final dir = Directory.systemTemp.createTempSync('passbook_visual');
    vaultPath = '${dir.path}/visual.vault';
    final v = VaultController();
    await v.createAt(vaultPath, 'master-pass');
    // 倒序插入：列表按创建时间新的在前。
    for (final s in _samples.reversed) {
      final e = v.addEntry();
      v.updateField(e, 'Title', s.$1);
      v.updateField(e, 'Notes', s.$2);
      v.updateField(e, 'UserName', s.$3);
      v.updateField(e, 'Password', s.$4);
      v.updateField(e, 'URL', s.$5);
    }
    await v.save();
    v.close();
  });

  testWidgets('01 解锁页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final vault = VaultController();
    final guard = IdleGuard();
    await tester.pumpWidget(_app(vault, guard, Brightness.light));
    await _settleReal(tester);
    await tester.pump();

    expect(find.text('输入主密码'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/01-lock-light.png'),
    );
  });

  testWidgets('02 列表页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final vault = VaultController();
    final guard = IdleGuard();
    await tester.pumpWidget(_app(vault, guard, Brightness.light));
    await _settleReal(tester);
    await _unlock(tester, vault);

    expect(find.text('招商银行'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/02-list-light.png'),
    );
  });

  testWidgets('03 编辑页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final vault = VaultController();
    final guard = IdleGuard();
    await tester.pumpWidget(_app(vault, guard, Brightness.light));
    await _settleReal(tester);
    await _unlock(tester, vault);

    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();

    expect(find.text('主账号，两段验证绑了手机'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/03-editor-light.png'),
    );
  });

  testWidgets('04 列表页（夜）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final vault = VaultController();
    final guard = IdleGuard();
    await tester.pumpWidget(_app(vault, guard, Brightness.dark));
    await _settleReal(tester);
    await _unlock(tester, vault);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/04-list-dark.png'),
    );
  });
}

/// 走真实 UI 解锁：`_unlocked` 是页面私有状态，直接调 `vault.open` 不会换页。
Future<void> _unlock(WidgetTester tester, VaultController vault) async {
  await tester.enterText(find.byType(TextField).first, 'master-pass');
  await tester.tap(find.text('进入 →'));
  // 读文件 + Argon2id 解密是真实 IO，要真实事件循环；pump 只推进假时钟。
  for (var i = 0; i < 25 && !vault.isOpen; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(vault.isOpen, isTrue, reason: '解锁没成功，后面的截图都会是解锁页');
}

Widget _app(VaultController vault, IdleGuard guard, Brightness brightness) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    // 测试环境没有系统字体映射，显式把本机加载进来的字体族注入主题。
    theme: buildAppTheme(
      brightness,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const ['Microsoft YaHei'],
    ),
    home: HomePage(vault: vault, idleGuard: guard),
  );
}

/// 让真实异步（文件读取、SharedPreferences）跑完——`pump` 只推进 fake 时钟。
Future<void> _settleReal(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
  );
  await tester.pump();
}

Future<void> _loadSystemFonts() async {
  Future<void> load(String family, List<String> paths) async {
    for (final p in paths) {
      final file = File(p);
      if (!file.existsSync()) continue;
      try {
        final bytes = await file.readAsBytes();
        final loader = FontLoader(family)
          ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
        await loader.load();
        return;
      } catch (_) {
        // 这个文件读不了就换下一个候选。
      }
    }
  }

  await load('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf']);
  await load('Microsoft YaHei', [
    'C:/Windows/Fonts/msyh.ttc',
    'C:/Windows/Fonts/simhei.ttf',
  ]);
  await load('Consolas', ['C:/Windows/Fonts/consola.ttf']);
  // 不加载图标字体的话，所有图标都渲染成方块——截图的装置缺陷，不是设计问题。
  await load('MaterialIcons', [
    'C:/Users/tr/flutter/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
  ]);
}

/// 示例内容不是占位符：列表的节奏感只能靠真实标题与真实长度的备注看出来。
/// 全部是编的，没有一个能登录任何地方。
const _samples = <(String, String, String, String, String)>[
  (
    '招商银行',
    '尾号 8891 · 登录用',
    'user8891',
    'Xk7#mQ2!pL9@vR4&',
    'https://cmbchina.com',
  ),
  (
    'GitHub',
    '主账号，两段验证绑了手机',
    'alice-dev',
    r'kR2$nH8*wE5^yU3',
    'https://github.com',
  ),
  ('家里路由器', '192.168.1.1 管理后台', 'admin', 'nR7!wQ3#zT8@kM2', ''),
  (
    'Notion',
    '工作区（团队）',
    'alice@example.com',
    r'pW4%tY6&uI1^oP9',
    'https://notion.so',
  ),
  ('网易云音乐', '会员账号', '13800000000', r'aL5#sD2!fG8@hJ3', ''),
  ('周末买', '猫粮、洗衣液、蓝牙耳机', '', '', ''),
];
