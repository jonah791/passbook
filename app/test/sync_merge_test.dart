import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/vault_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 同步的核心判据：**合并之后两边的条目必须一模一样，且谁的新东西都不许丢**。
/// 这里不涉及网络——网络那层只负责把密文搬过去，逻辑正确性全在这一层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 建一个库并把副本交给对端，模拟「两端本来是同一个库」。
  Future<(VaultController, VaultController, Directory)> pair(
    String password,
  ) async {
    final dir = Directory.systemTemp.createTempSync('passbook_sync');
    final pa = '${dir.path}${Platform.pathSeparator}a.kdbx';
    final pb = '${dir.path}${Platform.pathSeparator}b.kdbx';

    final a = VaultController();
    expect(await a.createAt(pa, password), isTrue, reason: a.lastError ?? '');
    await a.save();
    File(pa).copySync(pb);

    final b = VaultController();
    expect(await b.open(pb, password), isTrue, reason: b.lastError ?? '');
    return (a, b, dir);
  }

  Set<String> titlesOf(VaultController v) => {
    for (final e in v.allEntries) v.fieldOf(e, 'Title'),
  };

  test('两端各加一条，互相同步后都在', () async {
    final (a, b, dir) = await pair('sync-pw');

    final a1 = a.addEntry();
    a.updateField(a1, 'Title', 'A 新加');
    await a.save();

    final b1 = b.addEntry();
    b.updateField(b1, 'Title', 'B 新加');
    await b.save();

    // 双向同步（各自拉对方的密文合并）
    await b.mergeRemote(await a.exportBytes());
    await a.mergeRemote(await b.exportBytes());

    expect(titlesOf(a), containsAll(['A 新加', 'B 新加']));
    expect(titlesOf(a), titlesOf(b), reason: '合并后两端必须一致');
    expect(titlesOf(a).length, 2);

    a.close();
    b.close();
    dir.deleteSync(recursive: true);
  });

  test('一端删除，另一端同步后也消失（墓碑生效）', () async {
    final (a, b, dir) = await pair('sync-pw');

    final a1 = a.addEntry();
    a.updateField(a1, 'Title', '要被删的');
    final a2 = a.addEntry();
    a.updateField(a2, 'Title', '要留着的');
    await a.save();

    // 先把这两条同步到 B，让两端有共同基态
    await b.mergeRemote(await a.exportBytes());
    expect(titlesOf(b), containsAll(['要被删的', '要留着的']));

    // A 删掉一条
    a.deleteEntry(a1);
    await a.save();

    // B 合并 A 之后，那条不许复活
    await b.mergeRemote(await a.exportBytes());

    expect(titlesOf(b), isNot(contains('要被删的')));
    expect(titlesOf(b), contains('要留着的'));
    expect(titlesOf(a), titlesOf(b));

    a.close();
    b.close();
    dir.deleteSync(recursive: true);
  });

  test('同一条两边都改，保留改得晚的那份', () async {
    final (a, b, dir) = await pair('sync-pw');

    final seed = a.addEntry();
    a.updateField(seed, 'Title', '共同条目');
    await a.save();
    await b.mergeRemote(await a.exportBytes());

    // 找到两端各自的同一条（uuid 相同）
    final entryA = a.allEntries.first;
    final entryB = b.allEntries.first;

    a.updateField(entryA, 'Notes', 'A 改的');
    await a.save();
    // KDBX 时间精度到秒，隔开一秒才能让「谁更晚」没有歧义
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    b.updateField(entryB, 'Notes', 'B 改的');
    await b.save();

    await b.mergeRemote(await a.exportBytes());
    await a.mergeRemote(await b.exportBytes());

    expect(a.fieldOf(a.allEntries.first, 'Notes'), 'B 改的');
    expect(b.fieldOf(b.allEntries.first, 'Notes'), 'B 改的');

    a.close();
    b.close();
    dir.deleteSync(recursive: true);
  });

  test('幂等：同一份合两次，条目数不变', () async {
    final (a, b, dir) = await pair('sync-pw');

    final e = a.addEntry();
    a.updateField(e, 'Title', '只有一条');
    await a.save();

    final remote = await a.exportBytes();
    final first = await b.mergeRemote(remote);
    final second = await b.mergeRemote(remote);

    expect(first.after, 1);
    expect(second.after, 1, reason: '重复合并不许长出副本');
    expect(second.added, 0);

    a.close();
    b.close();
    dir.deleteSync(recursive: true);
  });

  test('冲突里输掉的那一版进历史，不是被删掉', () async {
    final (a, b, dir) = await pair('sync-pw');

    final seed = a.addEntry();
    a.updateField(seed, 'Title', '共同条目');
    await a.save();
    await b.mergeRemote(await a.exportBytes());

    a.updateField(a.allEntries.first, 'Notes', '早改的那份');
    await a.save();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    b.updateField(b.allEntries.first, 'Notes', '晚改的那份');
    await b.save();

    await a.mergeRemote(await b.exportBytes());

    final merged = a.allEntries.first;
    expect(a.fieldOf(merged, 'Notes'), '晚改的那份', reason: '当前值取晚的那份');
    // 「不丢改动」的**准确**含义：晚的赢，早的整条留在历史里可翻回去。
    // 别把它读成「同一条的两个字段各取各的」——KDBX 是条目级时间戳，
    // 并发改同一条时是整体择一，不是逐字段合并。
    final historyNotes = [
      for (final h in merged.history) h.fields['Notes']?.text ?? '',
    ];
    expect(
      historyNotes,
      contains('早改的那份'),
      reason: '输掉的那版必须在历史里，否则就是真丢了',
    );

    a.close();
    b.close();
    dir.deleteSync(recursive: true);
  });

  test('删除胜过并发编辑：墓碑优先，对端改了也不复活', () async {
    final (a, b, dir) = await pair('sync-pw');

    final seed = a.addEntry();
    a.updateField(seed, 'Title', '会被删的');
    await a.save();
    await b.mergeRemote(await a.exportBytes());

    // A 删，B 同时改（谁先谁后不影响结论：墓碑是集合成员关系，不是时间戳）
    a.deleteEntry(a.allEntries.first);
    await a.save();
    b.updateField(b.allEntries.first, 'Notes', 'B 这边改了一笔');
    await b.save();

    await b.mergeRemote(await a.exportBytes());
    await a.mergeRemote(await b.exportBytes());

    expect(titlesOf(b), isNot(contains('会被删的')));
    expect(titlesOf(a), isNot(contains('会被删的')));

    a.close();
    b.close();
    dir.deleteSync(recursive: true);
  });

  test('新设备（空库）第一次同步：整库接管对端', () async {
    final dir = Directory.systemTemp.createTempSync('passbook_adopt');
    final sep = Platform.pathSeparator;

    // 老设备：已经记了几条
    final old = VaultController();
    final oldPath = '${dir.path}${sep}old.kdbx';
    expect(await old.createAt(oldPath, 'same-pw'), isTrue, reason: old.lastError ?? '');
    for (final t in ['老库第一条', '老库第二条']) {
      final e = old.addEntry();
      old.updateField(e, 'Title', t);
    }
    await old.save();

    // 新设备：刚建的空库（根分组 uuid 与老库不同）
    final fresh = VaultController();
    final freshPath = '${dir.path}${sep}fresh.kdbx';
    expect(await fresh.createAt(freshPath, 'same-pw'), isTrue, reason: fresh.lastError ?? '');
    expect(fresh.allEntries, isEmpty);

    final result = await fresh.mergeRemote(await old.exportBytes());

    expect(result.adopted, isTrue, reason: '空库遇到另一个库应当接管');
    expect(titlesOf(fresh), containsAll(['老库第一条', '老库第二条']));
    expect(titlesOf(fresh).length, 2, reason: '接管后条目数等于对端');

    // 接管必须落盘：重新打开也要看得到（否则只是内存里换了）
    fresh.close();
    final reopened = VaultController();
    expect(await reopened.open(freshPath, 'same-pw'), isTrue, reason: reopened.lastError ?? '');
    expect(titlesOf(reopened), containsAll(['老库第一条', '老库第二条']));

    old.close();
    reopened.close();
    dir.deleteSync(recursive: true);
  });

  test('本机已有内容的库，不许被对端整库顶掉', () async {
    final dir = Directory.systemTemp.createTempSync('passbook_refuse');
    final sep = Platform.pathSeparator;

    final a = VaultController();
    await a.createAt('${dir.path}${sep}a.kdbx', 'same-pw');
    final ea = a.addEntry();
    a.updateField(ea, 'Title', 'A 的条目');
    await a.save();

    final other = VaultController();
    await other.createAt('${dir.path}${sep}other.kdbx', 'same-pw');
    final eo = other.addEntry();
    other.updateField(eo, 'Title', '另一个库的条目');
    await other.save();

    await expectLater(
      a.mergeRemote(await other.exportBytes()),
      throwsA(isA<StateError>()),
      reason: '不同库 + 本地有内容 ⇒ 必须拒绝，不能静默覆盖',
    );
    expect(titlesOf(a), {'A 的条目'}, reason: '拒绝之后本地内容一点都不能变');

    a.close();
    other.close();
    dir.deleteSync(recursive: true);
  });
}
