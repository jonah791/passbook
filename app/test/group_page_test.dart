import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kpasslib/kpasslib.dart';
import 'package:passbook/core/vault_controller.dart';
import 'package:passbook/pages/group_page.dart';

/// 分组整理页：建、改名、删。
///
/// 用内存库而不是真库文件：这一页只跟 `vault.groups` 打交道，不读写磁盘，
/// 走真文件只会把 FakeAsync 与真实 I/O 混在一起，得不偿失（列表页那边试过）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KdbxDatabase db;
  late _FakeGroupVault vault;

  setUp(() {
    db = KdbxDatabase.create(
      credentials: KdbxCredentials(password: ProtectedData.fromString('x')),
      name: 'test',
    );
    vault = _FakeGroupVault(db);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: GroupPage(vault: vault)));
    await tester.pump();
  }

  testWidgets('一个分组都没有时说清楚去哪建', (tester) async {
    await pumpPage(tester);

    expect(find.text('还没有分组'), findsOneWidget);
    expect(find.text('建一个分组'), findsOneWidget);
  });

  testWidgets('建一个分组，列表里立刻出现', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byTooltip('新建分组'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '工作');
    await tester.tap(find.text('建好'));
    await tester.pumpAndSettle();

    expect(find.text('工作'), findsOneWidget);
    expect(find.text('0 条'), findsOneWidget);
    expect(vault.groups.single.name, '工作');
  });

  testWidgets('改名字', (tester) async {
    db.createGroup(parent: db.root, name: '工作');
    await pumpPage(tester);

    await tester.tap(find.byTooltip('重命名或删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('改名字'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '公司');
    await tester.tap(find.text('改好'));
    await tester.pumpAndSettle();

    expect(find.text('公司'), findsOneWidget);
    expect(find.text('工作'), findsNothing);
  });

  testWidgets('删分组要先说清楚条目不会跟着消失', (tester) async {
    final group = db.createGroup(parent: db.root, name: '临时');
    db.createEntry(parent: group);
    await pumpPage(tester);

    await tester.tap(find.byTooltip('重命名或删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删掉分组'));
    await tester.pumpAndSettle();

    expect(find.textContaining('不会删掉这些东西'), findsOneWidget);
    expect(find.text('1 条'), findsOneWidget);

    await tester.tap(find.text('删掉'));
    await tester.pumpAndSettle();

    expect(vault.groups, isEmpty);
    expect(vault.allEntries.length, 1, reason: '条目回到未分组，不许跟着消失');
  });

  testWidgets('空分组删除时不必吓唬人', (tester) async {
    db.createGroup(parent: db.root, name: '空的');
    await pumpPage(tester);

    await tester.tap(find.byTooltip('重命名或删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删掉分组'));
    await tester.pumpAndSettle();

    expect(find.textContaining('这个分组是空的'), findsOneWidget);
  });
}

/// 用内存库回答分组问题，不碰磁盘也不起防抖定时器。
class _FakeGroupVault extends VaultController {
  _FakeGroupVault(this.db);

  final KdbxDatabase db;

  @override
  List<KdbxGroup> get groups {
    final bin = db.meta.recycleBinUuid;
    final list = db.root.groups.where((g) => g.uuid != bin).toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  @override
  List<KdbxEntry> get allEntries => db.root.allEntries;

  @override
  KdbxGroup? groupOf(KdbxEntry entry) {
    final parent = entry.parent;
    if (parent == null || parent.uuid == db.root.uuid) return null;
    return parent;
  }

  @override
  KdbxGroup createGroup(String name) {
    final group = db.createGroup(parent: db.root, name: name.trim());
    notifyListeners();
    return group;
  }

  @override
  void renameGroup(KdbxGroup group, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == group.name) return;
    group.name = trimmed;
    group.times.touch();
    notifyListeners();
  }

  @override
  void deleteGroup(KdbxGroup group) {
    for (final entry in List<KdbxEntry>.of(group.entries)) {
      db.move(item: entry, target: db.root);
    }
    for (final child in List<KdbxGroup>.of(group.groups)) {
      db.move(item: child, target: db.root);
    }
    db.move(item: group);
    notifyListeners();
  }

  @override
  void scheduleSave() {}

  @override
  Future<void> flushNow() async {}

  @override
  void close() {}
}
