import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kpasslib/kpasslib.dart';
import 'package:passbook/core/vault_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 分组的判据只有两条：**整理之后东西还能找回来**，以及**整理本身不会弄丢东西**。
/// 第二条最容易错——删组、改名、跨端合并，每一个都可能把条目从「有归属」变成
/// 「凭空消失」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<(VaultController, Directory)> fresh() async {
    final dir = Directory.systemTemp.createTempSync('passbook_group');
    final path = '${dir.path}${Platform.pathSeparator}v.kdbx';
    final vault = VaultController();
    expect(
      await vault.createAt(path, 'group-pw'),
      isTrue,
      reason: vault.lastError ?? '',
    );
    return (vault, dir);
  }

  test('新库不自带任何分组', () async {
    final (vault, dir) = await fresh();
    expect(vault.groups, isEmpty, reason: '空壳分组只会让人以为东西被放进去了');
    vault.close();
    dir.deleteSync(recursive: true);
  });

  test('分组按名称排序，不随建组顺序', () async {
    final (vault, dir) = await fresh();
    vault.createGroup('丙');
    vault.createGroup('甲');
    vault.createGroup('乙');
    expect(vault.groups.map((g) => g.name).toList(), ['丙', '乙', '甲']);
    vault.close();
    dir.deleteSync(recursive: true);
  });

  test('条目挪进分组、再挪回未分组', () async {
    final (vault, dir) = await fresh();
    final work = vault.createGroup('工作');
    final entry = vault.addEntry();
    vault.updateField(entry, 'Title', '报销单');

    expect(vault.groupOf(entry), isNull, reason: '新条目默认未分组');
    expect(vault.entriesOf(null).length, 1);

    vault.moveEntry(entry, work);
    expect(vault.groupOf(entry)?.name, '工作');
    expect(vault.entriesOf(work).single, same(entry));
    expect(vault.entriesOf(null).length, 1, reason: '「全部」永远看得见所有条目');

    vault.moveEntry(entry, null);
    expect(vault.groupOf(entry), isNull);
    expect(vault.entriesOf(work), isEmpty);

    vault.close();
    dir.deleteSync(recursive: true);
  });

  test('删分组不删条目：里面的东西回到未分组', () async {
    final (vault, dir) = await fresh();
    final temp = vault.createGroup('临时');
    final entry = vault.addEntry(parent: temp);
    vault.updateField(entry, 'Title', '别弄丢');
    expect(vault.entriesOf(temp).length, 1);

    vault.deleteGroup(temp);

    expect(vault.groups, isEmpty);
    expect(vault.allEntries.length, 1, reason: '条目不许跟着分组一起消失');
    expect(vault.groupOf(entry), isNull);
    expect(vault.fieldOf(entry, 'Title'), '别弄丢');

    vault.close();
    dir.deleteSync(recursive: true);
  });

  test('改名去掉首尾空白；空名字等于没改', () async {
    final (vault, dir) = await fresh();
    final group = vault.createGroup('工作');
    vault.renameGroup(group, '  公司  ');
    expect(group.name, '公司');

    vault.renameGroup(group, '   ');
    expect(group.name, '公司', reason: '空名字不该把分组名抹成空白');

    vault.close();
    dir.deleteSync(recursive: true);
  });

  test('分组与归属都会落盘，重开还在', () async {
    final (vault, dir) = await fresh();
    final group = vault.createGroup('工作');
    vault.addEntry(parent: group);
    vault.renameGroup(group, '公司');
    await vault.flushNow();
    final path = vault.filePath!;
    vault.close();

    final reopened = VaultController();
    expect(
      await reopened.open(path, 'group-pw'),
      isTrue,
      reason: reopened.lastError ?? '',
    );
    expect(reopened.groups.single.name, '公司');
    expect(reopened.entriesOf(reopened.groups.single).length, 1);
    reopened.close();
    dir.deleteSync(recursive: true);
  });

  test('回收站不算分组：别的客户端删过东西，回收站不该出现在列表里', () async {
    final dir = Directory.systemTemp.createTempSync('passbook_group_bin');
    final path = '${dir.path}${Platform.pathSeparator}bin.kdbx';

    // 用库自己的能力造一个「有回收站」的库——这正是别的客户端删条目的样子。
    final db = KdbxDatabase.create(
      credentials: KdbxCredentials(
        password: ProtectedData.fromString('bin-pw'),
      ),
      name: 'Passbook',
    );
    db.meta.recycleBinEnabled = true;
    final work = db.createGroup(parent: db.root, name: '工作');
    db.remove(db.createEntry(parent: work)); // 进回收站（会顺手建一个）
    expect(db.meta.recycleBinUuid, isNotNull, reason: '夹具前提：库里确实有回收站');
    await File(path).writeAsBytes(await db.save());

    final vault = VaultController();
    expect(
      await vault.open(path, 'bin-pw'),
      isTrue,
      reason: vault.lastError ?? '',
    );
    expect(
      vault.groups.map((g) => g.name).toList(),
      ['工作'],
      reason: '回收站不是给人用的分组，混进来会让人以为东西还在',
    );

    vault.close();
    dir.deleteSync(recursive: true);
  });

  test('删分组时，它下面的子分组上移而不是一起消失', () async {
    final dir = Directory.systemTemp.createTempSync('passbook_group_sub');
    final path = '${dir.path}${Platform.pathSeparator}sub.kdbx';

    // 子分组只有别的客户端会建（这个界面只做一层），所以夹具走库本身。
    final db = KdbxDatabase.create(
      credentials: KdbxCredentials(
        password: ProtectedData.fromString('sub-pw'),
      ),
      name: 'Passbook',
    );
    final parent = db.createGroup(parent: db.root, name: '父组');
    db.createGroup(parent: parent, name: '子组');
    db.createEntry(parent: parent); // 直接挂在父组下的条目
    await File(path).writeAsBytes(await db.save());

    final vault = VaultController();
    expect(
      await vault.open(path, 'sub-pw'),
      isTrue,
      reason: vault.lastError ?? '',
    );
    expect(vault.groups.map((g) => g.name).toList(), ['父组']);

    vault.deleteGroup(vault.groups.first);

    expect(
      vault.groups.map((g) => g.name).toList(),
      ['子组'],
      reason: '子分组上移到根，不跟着被删',
    );
    expect(vault.allEntries.length, 1, reason: '子组里的条目也不许丢');

    vault.close();
    dir.deleteSync(recursive: true);
  });

  test('两端各自建组放条目，合并后分组与归属都在', () async {
    final dir = Directory.systemTemp.createTempSync('passbook_group_sync');
    final pa = '${dir.path}${Platform.pathSeparator}a.kdbx';
    final pb = '${dir.path}${Platform.pathSeparator}b.kdbx';

    final a = VaultController();
    expect(await a.createAt(pa, 'p'), isTrue, reason: a.lastError ?? '');
    await a.save();
    File(pa).copySync(pb);

    final b = VaultController();
    expect(await b.open(pb, 'p'), isTrue, reason: b.lastError ?? '');

    final work = a.createGroup('工作');
    a.updateField(a.addEntry(parent: work), 'Title', 'A 的工资条');
    await a.save();

    final home = b.createGroup('家里');
    b.updateField(b.addEntry(parent: home), 'Title', 'B 的水电费');
    await b.save();

    await b.mergeRemote(await a.exportBytes());
    await a.mergeRemote(await b.exportBytes());

    KdbxGroup? groupOfTitle(VaultController v, String title) {
      for (final e in v.allEntries) {
        if (v.fieldOf(e, 'Title') == title) return v.groupOf(e);
      }
      return null;
    }

    for (final v in [a, b]) {
      expect(
        v.groups.map((g) => g.name).toSet(),
        {'工作', '家里'},
        reason: '两边的分组都要在',
      );
      expect(groupOfTitle(v, 'A 的工资条')?.name, '工作', reason: '归属不许在合并中丢失');
      expect(groupOfTitle(v, 'B 的水电费')?.name, '家里');
      expect(v.allEntries.length, 2);
    }

    a.close();
    b.close();
    dir.deleteSync(recursive: true);
  });
}
