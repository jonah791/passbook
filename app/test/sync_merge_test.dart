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
}
