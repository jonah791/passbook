import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kpasslib/kpasslib.dart';
import 'package:passbook/core/vault_controller.dart';
import 'package:passbook/pages/group_page.dart';
import 'package:passbook/pages/home_page.dart';

/// 编辑页里「分组」那一行。
///
/// 只验接线：显示当前分组 → 点开能选 → 选完真的挪了。分组本身的增删改由
/// group_test.dart 负责，这里不重复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KdbxDatabase db;
  late KdbxEntry entry;
  late _FakeGroupVault vault;

  setUp(() {
    db = KdbxDatabase.create(
      credentials: KdbxCredentials(password: ProtectedData.fromString('x')),
      name: 'test',
    );
    entry = db.createEntry(parent: db.root);
    vault = _FakeGroupVault(db);
  });

  Future<void> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: NoteEditorPage(vault: vault, entry: entry)),
    );
    await tester.pump();
  }

  testWidgets('未分组时，标题下面写着「未分组」', (tester) async {
    await pumpEditor(tester);
    expect(find.text(ungroupedLabel), findsOneWidget);
  });

  testWidgets('点开就能选分组，选完这一行跟着变', (tester) async {
    db.createGroup(parent: db.root, name: '工作');
    await pumpEditor(tester);

    await tester.tap(find.text(ungroupedLabel));
    await tester.pumpAndSettle();
    expect(find.text('放进哪个分组'), findsOneWidget);

    await tester.tap(find.widgetWithText(SimpleDialogOption, '工作'));
    await tester.pumpAndSettle();

    expect(find.text('工作'), findsOneWidget);
    expect(vault.moved, isTrue);
    expect(vault.groupOf(entry)?.name, '工作');
  });

  testWidgets('一个分组都没有时，选择器告诉你去哪建', (tester) async {
    await pumpEditor(tester);

    await tester.tap(find.text(ungroupedLabel));
    await tester.pumpAndSettle();

    expect(find.textContaining('还没有分组'), findsOneWidget);
  });

  testWidgets('当前所在的那个选项带勾', (tester) async {
    await pumpEditor(tester);

    await tester.tap(find.text(ungroupedLabel));
    await tester.pumpAndSettle();

    // 未分组是当前状态，所以只有它带勾。
    expect(find.byIcon(Icons.check), findsOneWidget);
  });
}

/// 用内存库回答分组问题，不碰磁盘也不起防抖定时器。
class _FakeGroupVault extends VaultController {
  _FakeGroupVault(this.db);

  final KdbxDatabase db;
  final Map<String, String> fields = <String, String>{};
  bool moved = false;

  @override
  List<KdbxGroup> get groups {
    final bin = db.meta.recycleBinUuid;
    final list = db.root.groups.where((g) => g.uuid != bin).toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  @override
  KdbxGroup? groupOf(KdbxEntry entry) {
    final parent = entry.parent;
    if (parent == null || parent.uuid == db.root.uuid) return null;
    return parent;
  }

  @override
  void moveEntry(KdbxEntry entry, KdbxGroup? target) {
    db.move(item: entry, target: target ?? db.root);
    moved = true;
  }

  @override
  String fieldOf(KdbxEntry entry, String key) => fields[key] ?? '';

  @override
  void updateField(KdbxEntry entry, String key, String value) {
    fields[key] = value;
  }

  @override
  void scheduleSave() {}

  @override
  Future<void> flushNow() async {}

  @override
  void close() {}
}
