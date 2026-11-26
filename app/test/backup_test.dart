import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/backup.dart';
import 'package:passbook/core/vault_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 备份与恢复的两条路语义不同，这里把差别钉成测试：
/// 合并只增不减、替换真的会丢东西、替换前那份「后悔药」必须真能打开。
///
/// 用真 KDBX 跑（kpasslib 是纯 Dart，不碰平台通道），不桩掉加密——
/// 备份功能的价值全在「密文与主密码配合」，把它 mock 掉就什么都没测到。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory backupDir;
  late VaultController vault;

  const pass = 'master-pass';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('passbook_backup');
    backupDir = Directory('${tmp.path}${Platform.pathSeparator}backups');
    vault = VaultController();
  });

  tearDown(() {
    vault.close();
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
  });

  Future<void> boot() async {
    expect(await vault.createAt('${tmp.path}${Platform.pathSeparator}v.kdbx', pass), isTrue);
    backupDir.createSync(recursive: true);
  }

  BackupService svc() => BackupService(vault, directory: backupDir);

  Future<void> addTitle(String title) async {
    final e = vault.addEntry();
    vault.updateField(e, 'Title', title);
    await vault.flushNow();
  }

  group('导出', () {
    test('写出的字节就是库的密文，且不留半截文件', () async {
      await boot();
      await addTitle('第一条');

      final target = File('${tmp.path}${Platform.pathSeparator}out.kdbx');
      final n = await svc().exportTo(target);

      expect(n, greaterThan(0));
      expect(await target.length(), n);
      expect(
        File('${tmp.path}${Platform.pathSeparator}out.kdbx.part').existsSync(),
        isFalse,
        reason: '写完要改名收尾，不能留下 .part',
      );

      // 判据不能是「字节与再导一次相同」：KDBX 每次保存都换新随机数重新加密，
      // 两份字节必然不同、但都合法。所以只能验「打得开、内容对」。
      // 反过来说：**拿备份文件的 sha256 当「有没有变」的判据一定会误判**。
      expect(
        await target.readAsBytes(),
        isNot(await vault.exportBytes()),
        reason: '重新加密是 KDBX 的正常行为，字节不该被当成内容指纹',
      );
      final reopened = VaultController();
      expect(await reopened.open(target.path, pass), isTrue);
      expect(reopened.allEntries.length, 1);
      expect(reopened.fieldOf(reopened.allEntries.first, 'Title'), '第一条');
      reopened.close();
    });

    test('历史备份出现在列表里，文件名带时间戳', () async {
      await boot();
      await addTitle('一条');

      final f = await svc().exportHistory(now: DateTime(2026, 11, 26, 16, 33));
      expect(f.path, endsWith('passbook-20261126-1633.kdbx'));

      final list = await svc().listHistory();
      expect(list.length, 1);
      expect(list.first.path, f.path);
    });

    test('导出的备份能被主密码打开，条目数一致', () async {
      await boot();
      await addTitle('甲');
      await addTitle('乙');

      final f = await svc().exportHistory(now: DateTime(2026, 11, 26, 9, 0));

      final opened = VaultController();
      expect(await opened.open(f.path, pass), isTrue);
      expect(opened.allEntries.length, 2);
      opened.close();

      // 负样本：错误密码打不开，说明它真的是密文
      final wrong = VaultController();
      expect(await wrong.open(f.path, 'not-the-pass'), isFalse);
      wrong.close();
    });
  });

  group('恢复：合并', () {
    test('备份里独有的条目补进来，现有条目一条不少', () async {
      await boot();
      await addTitle('备份前的');
      final backup = await svc().exportHistory(now: DateTime(2026, 11, 26, 16, 0));

      await addTitle('备份后的');
      expect(vault.allEntries.length, 2);

      final r = await svc().mergeFrom(backup);
      expect(vault.allEntries.length, 2);
      expect(r.after, 2);
      final titles = vault.allEntries
          .map((e) => vault.fieldOf(e, 'Title'))
          .toSet();
      expect(titles, containsAll(<String>['备份前的', '备份后的']));
    });
  });

  group('恢复：替换', () {
    test('库回到备份那一刻，备份之后新增的消失，后悔药真能打开', () async {
      await boot();
      await addTitle('备份前的');
      final backup = await svc().exportHistory(now: DateTime(2026, 11, 26, 16, 0));

      await addTitle('备份后的');
      expect(vault.allEntries.length, 2);

      final safety = await svc().replaceFrom(backup);

      expect(vault.allEntries.length, 1);
      expect(vault.fieldOf(vault.allEntries.first, 'Title'), '备份前的');

      expect(safety.existsSync(), isTrue, reason: '替换前必须留下现状');
      final check = VaultController();
      expect(await check.open(safety.path, pass), isTrue);
      expect(
        check.allEntries.length,
        2,
        reason: '后悔药里应该还是替换前的 2 条',
      );
      check.close();
    });

    test('替换用的文件密码不对时抛异常，且当前库保持原样', () async {
      await boot();
      await addTitle('原有内容');
      final before = vault.allEntries.length;

      // 用另一个密码造一份外人库
      final other = VaultController();
      final otherPath = '${tmp.path}${Platform.pathSeparator}other.kdbx';
      expect(await other.createAt(otherPath, 'another-pass'), isTrue);
      other.close();

      await expectLater(
        svc().replaceFrom(File(otherPath)),
        throwsA(anything),
      );
      expect(vault.allEntries.length, before, reason: '先验后换：解不开就不许动');
      expect(vault.fieldOf(vault.allEntries.first, 'Title'), '原有内容');
    });
  });

  group('删除的边界', () {
    test('只允许删备份目录里的 .kdbx', () async {
      await boot();
      final s = svc();

      final outside = File('${tmp.path}${Platform.pathSeparator}outside.kdbx')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      await expectLater(
        s.deleteHistory(outside),
        throwsA(isA<ArgumentError>()),
        reason: '目录外的一律不许删',
      );
      expect(outside.existsSync(), isTrue);

      final notKdbx = File('${backupDir.path}${Platform.pathSeparator}x.txt')
        ..writeAsBytesSync(<int>[1]);
      await expectLater(
        s.deleteHistory(notKdbx),
        throwsA(isA<ArgumentError>()),
        reason: '只认 .kdbx',
      );
      expect(notKdbx.existsSync(), isTrue);

      final saved = await s.exportHistory(now: DateTime(2026, 11, 26, 12, 0));
      await s.deleteHistory(saved);
      expect(saved.existsSync(), isFalse);
    });
  });

  group('显示用的格式化', () {
    test('字节数分档', () {
      expect(BackupService.humanSize(512), '512 B');
      expect(BackupService.humanSize(2048), '2.0 KB');
      expect(BackupService.humanSize(5 * 1024 * 1024), '5.0 MB');
    });

    test('从文件名还原时间', () {
      final f = File('/x/backups/passbook-20261126-1633.kdbx');
      expect(BackupService.humanTime(f), '11-26 16:33');
    });

    test('文件名就是 pubspec 之外唯一的时间锚点格式', () {
      expect(
        BackupService.suggestedName(DateTime(2026, 1, 2, 3, 4)),
        'passbook-20260102-0304.kdbx',
      );
    });
  });
}
