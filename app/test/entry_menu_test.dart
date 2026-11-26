import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/idle_guard.dart';
import 'package:passbook/core/vault_controller.dart';
import 'package:passbook/pages/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 列表页的条目菜单：桌面端右键、安卓长按。
///
/// 两边共用一份菜单，所以两路手势都要验——只验长按的话，右键那条线断了
/// 也不会有测试变红，而它恰恰是主人在这台机器上唯一能用的那一路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VaultController vault;

  const masterPass = 'menu-pass';

  // 每个测试各建一份库：删除测试会真的把条目删掉，共用一份就会让后面的
  // 测试看到一个缺了东西的库，而那种红看起来像功能坏了。
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final dir = Directory.systemTemp.createTempSync('passbook_menu');
    final seed = VaultController();
    await seed.createAt('${dir.path}/menu.vault', masterPass);
    // 全字段的一条：三个复制项都该出现。
    final full = seed.addEntry();
    seed.updateField(full, 'Title', 'GitHub');
    seed.updateField(full, 'Notes', '主账号');
    seed.updateField(full, 'UserName', 'alice-dev');
    seed.updateField(full, 'Password', r'kR2$nH8*wE5^yU3');
    seed.updateField(full, 'URL', 'https://github.com');
    // 只有标题的一条：复制项一个都不该出现。
    final plain = seed.addEntry();
    seed.updateField(plain, 'Title', '周末买');
    seed.updateField(plain, 'Notes', '猫粮');
    seed.createGroup('工作');
    await seed.save();
    seed.close();

    vault = VaultController();
  });

  tearDown(() {
    vault.close();
  });

  /// 打开列表页并真的解锁。`_unlocked` 是页面私有状态，只能走 UI。
  Future<void> pumpList(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(vault: vault, idleGuard: IdleGuard()),
      ),
    );
    // 读偏好、读库文件都是真实 IO：pump 只推进假时钟。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, masterPass);
    await tester.tap(find.text('进入 →'));
    for (var i = 0; i < 25 && !vault.isOpen; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(vault.isOpen, isTrue, reason: '没解锁，后面的菜单都不会出现');
    expect(find.text('GitHub'), findsOneWidget);
  }

  testWidgets('安卓长按弹菜单', (tester) async {
    await pumpList(tester);

    await tester.longPress(find.text('GitHub'));
    await tester.pumpAndSettle();

    expect(find.text('复制密码'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('移到分组'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('桌面右键弹同一份菜单', (tester) async {
    await pumpList(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('GitHub')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('复制密码'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('移到分组'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('复制项按字段有无出，空条目一个都不给', (tester) async {
    await pumpList(tester);

    await tester.longPress(find.text('GitHub'));
    await tester.pumpAndSettle();
    expect(find.text('复制密码'), findsOneWidget);
    expect(find.text('复制用户名'), findsOneWidget);
    expect(find.text('复制网址'), findsOneWidget);

    // 点菜单外面关掉它。
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('周末买'));
    await tester.pumpAndSettle();
    expect(find.text('复制密码'), findsNothing);
    expect(find.text('复制用户名'), findsNothing);
    expect(find.text('复制网址'), findsNothing);
    expect(find.text('编辑'), findsOneWidget);
  });

  testWidgets('移到分组：选完库里的归属跟着变', (tester) async {
    await pumpList(tester);

    await tester.longPress(find.text('GitHub'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移到分组'));
    await tester.pumpAndSettle();
    expect(find.text('放进哪个分组'), findsOneWidget);

    await tester.tap(find.widgetWithText(SimpleDialogOption, '工作'));
    await tester.pumpAndSettle();

    final entry = vault.allEntries.firstWhere(
      (e) => vault.fieldOf(e, 'Title') == 'GitHub',
    );
    expect(vault.groupOf(entry)?.name, '工作');

    // 挪完会起一个 800ms 的防抖保存定时器。制造把时钟推过去，否则测试结束时
    // 它还挂着，框架会当成「有东西没停」判红——那是装置的事，不是功能的。
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('删除要先确认，确认后条目从列表里消失', (tester) async {
    await pumpList(tester);

    await tester.longPress(find.text('GitHub'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 确认框里点名是哪一条：只写「删除这条？」的时候，相邻两条长得像就会误删。
    expect(find.text('删除「GitHub」？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('GitHub'), findsNothing);
    expect(
      vault.allEntries.where((e) => vault.fieldOf(e, 'Title') == 'GitHub'),
      isEmpty,
    );
  });

  testWidgets('搜不到时说「没匹配」，不说「库是空的」', (tester) async {
    await pumpList(tester);

    await tester.enterText(find.byType(TextField).first, 'zzz');
    await tester.pumpAndSettle();

    // 这两句的区别是：一个说你的东西丢了，一个说只是没搜到。
    expect(find.text('没有匹配「zzz」的条目'), findsOneWidget);
    expect(find.text('还什么都没记'), findsNothing);

    await tester.tap(find.text('清除搜索'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsOneWidget);
  });

  testWidgets('Esc 清空搜索', (tester) async {
    await pumpList(tester);

    await tester.enterText(find.byType(TextField).first, 'GitHub');
    await tester.pumpAndSettle();
    expect(find.text('周末买'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('周末买'), findsOneWidget);
  });

  testWidgets('长按分组条能改名', (tester) async {
    await pumpList(tester);

    await tester.longPress(find.text('工作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('改名'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '工作台');
    await tester.tap(find.text('改好'));
    await tester.pumpAndSettle();

    expect(find.text('工作台'), findsOneWidget);
    expect(vault.groups.map((g) => g.name), contains('工作台'));

    // 改名会起一个 800ms 的防抖保存定时器，把时钟推过去再结束。
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('全部视图里，条目缀着它所在的分组', (tester) async {
    await pumpList(tester);

    final entry = vault.allEntries.firstWhere(
      (e) => vault.fieldOf(e, 'Title') == 'GitHub',
    );
    vault.moveEntry(entry, vault.groups.first);
    await tester.pump();

    // 预览与分组名同在一条里：多一行会让每条记录变高，一屏少看几条。
    expect(find.textContaining('· 工作'), findsOneWidget);

    // 已经按分组筛着的时候不再缀：那时每行写着同一个名字，是噪音。
    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();
    expect(find.textContaining('· 工作'), findsNothing);

    // 收掉移动时起的保存定时器。
    await tester.pump(const Duration(milliseconds: 900));
  });
}
