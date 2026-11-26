import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kpasslib/kpasslib.dart';
import 'package:passbook/core/vault_controller.dart';
import 'package:passbook/pages/home_page.dart';

/// 编辑页里「动态验证码」那一块。
///
/// 这一层只验**接线**：字段里的密钥 → 界面上的码 → 编辑 / 删除又写回字段。
/// 「算得对不对」由 totp_test.dart 用 RFC 向量负责——这里故意不写死期望的码，
/// 因为界面上那个码取的是真实时钟，写死必然在某一天的某一秒变成 flaky。
/// 能在这里稳定断言的只有形状：一串 3+3 的数字。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// RFC 4226 的共享密钥，Base32 写法。
  const secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

  late KdbxEntry entry;
  late _FakeEditorVault vault;

  setUp(() {
    // 纯内存建库：KdbxDatabase.create 不碰磁盘，createEntry 也只是加一个对象。
    final db = KdbxDatabase.create(
      credentials: KdbxCredentials(password: ProtectedData.fromString('x')),
      name: 'test',
    );
    entry = db.createEntry(parent: db.root);
    vault = _FakeEditorVault();
  });

  Future<void> pumpEditor(WidgetTester tester) async {
    // 编辑页内容超过默认的 800x600，底部（动态验证码那一块）会落在可视区之外
    // 而根本不 build。把窗口放高，比在用例里滚动更稳。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: NoteEditorPage(vault: vault, entry: entry)),
    );
    await tester.pump();
  }

  /// 每秒刷新的倒计时定时器在跑时不能用 pumpAndSettle：它永远等不到「没有新帧」。
  Future<void> settleShort(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('没设置时只看到一个入口', (tester) async {
    await pumpEditor(tester);

    expect(find.byKey(const ValueKey('otp-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('otp-code')), findsNothing);
  });

  testWidgets('字段里有密钥时，界面显示分组后的码', (tester) async {
    vault.fields['otp'] = secret;
    await pumpEditor(tester);

    final code = tester.widget<Text>(find.byKey(const ValueKey('otp-code')));
    expect(code.data, matches(RegExp(r'^\d{3} \d{3}$')));
    expect(find.byKey(const ValueKey('otp-add')), findsNothing);
  });

  testWidgets('粘贴不合法的东西时，说清楚哪里不对', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.byKey(const ValueKey('otp-add')));
    await settleShort(tester);

    await tester.enterText(
      find.byKey(const ValueKey('otp-input')),
      '这不是密钥',
    );
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await settleShort(tester);

    // 不能只说「无效」：得说明是 Base32 的问题，用户才知道该改什么。
    expect(find.textContaining('Base32'), findsOneWidget);
    expect(vault.fields['otp'] ?? '', isEmpty);
  });

  testWidgets('保存合法密钥后写进 otp 字段，并立刻显示码', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.byKey(const ValueKey('otp-add')));
    await settleShort(tester);

    await tester.enterText(find.byKey(const ValueKey('otp-input')), secret);
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await settleShort(tester);

    expect(vault.fields['otp'], secret);
    expect(vault.saves, greaterThan(0), reason: '改动要触发落盘调度');
    expect(find.byKey(const ValueKey('otp-code')), findsOneWidget);
  });

  testWidgets('otpauth 链接也能存下来（存原文，不存解析结果）', (tester) async {
    const uri = 'otpauth://totp/GitHub:octocat?secret=$secret&issuer=GitHub';
    await pumpEditor(tester);
    await tester.tap(find.byKey(const ValueKey('otp-add')));
    await settleShort(tester);

    await tester.enterText(find.byKey(const ValueKey('otp-input')), uri);
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await settleShort(tester);

    expect(vault.fields['otp'], uri);
    expect(find.text('GitHub · octocat'), findsOneWidget);
  });

  testWidgets('删掉验证码要过一次确认，确认后字段清空', (tester) async {
    vault.fields['otp'] = secret;
    await pumpEditor(tester);

    await tester.tap(find.byKey(const ValueKey('otp-remove')));
    await settleShort(tester);
    expect(find.text('删掉这个验证码？'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await settleShort(tester);

    expect(vault.fields['otp'], isEmpty);
    expect(find.byKey(const ValueKey('otp-add')), findsOneWidget);
  });

  testWidgets('取消确认就什么都不动', (tester) async {
    vault.fields['otp'] = secret;
    await pumpEditor(tester);

    await tester.tap(find.byKey(const ValueKey('otp-remove')));
    await settleShort(tester);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settleShort(tester);

    expect(vault.fields['otp'], secret);
    expect(find.byKey(const ValueKey('otp-code')), findsOneWidget);
  });
}

/// 只回答「这个字段现在是什么」的假控制器：不碰磁盘，也不起防抖定时器。
class _FakeEditorVault extends VaultController {
  final Map<String, String> fields = <String, String>{};
  int saves = 0;

  @override
  String fieldOf(KdbxEntry entry, String key) => fields[key] ?? '';

  @override
  void updateField(KdbxEntry entry, String key, String value) {
    fields[key] = value;
  }

  @override
  void scheduleSave() {
    saves++;
  }

  @override
  Future<void> flushNow() async {}

  @override
  void close() {}
}
