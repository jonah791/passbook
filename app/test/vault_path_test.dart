import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/vault_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 库文件放哪、放不放得进去——这块的判据是「实测能写」，不是「目录看着在」。
/// 背景：这台机器开着 Windows 受控文件夹访问，文档目录读得到、写不进，
/// 用户第一次建库就撞墙，而报错是误导性的「找不到文件」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('跳过写不进去的候选目录，落在能写的那个', () async {
    final dir = Directory.systemTemp.createTempSync('passbook_pick');
    // 拿一个「文件」当候选目录：往它下面写一定失败。
    final blocker = File('${dir.path}${Platform.pathSeparator}blocker.txt');
    blocker.writeAsStringSync('x');

    final picked = await VaultController.pickWritable([blocker.path, dir.path]);

    expect(picked, isNotNull);
    expect(picked, contains(dir.path));
    expect(picked, endsWith('passbook.kdbx'));
    // 探针不许留下垃圾。
    expect(
      File(
        '${dir.path}${Platform.pathSeparator}passbook-write-probe.tmp',
      ).existsSync(),
      isFalse,
    );

    dir.deleteSync(recursive: true);
  });

  test('所有候选都写不进去时返回 null，不乱选一个', () async {
    final dir = Directory.systemTemp.createTempSync('passbook_pick2');
    final blocker = File('${dir.path}${Platform.pathSeparator}blocker.txt');
    blocker.writeAsStringSync('x');

    expect(await VaultController.pickWritable([blocker.path]), isNull);

    dir.deleteSync(recursive: true);
  });

  test('父目录不存在时 save 会自己建出来', () async {
    final dir = Directory.systemTemp.createTempSync('passbook_mkdir');
    // 两级都不存在：writeAsBytes 不会替你建目录，这一步必须自己保证。
    final path =
        '${dir.path}${Platform.pathSeparator}nested'
        '${Platform.pathSeparator}deep${Platform.pathSeparator}v.kdbx';

    final vault = VaultController();
    expect(
      await vault.createAt(path, 'pw-for-mkdir'),
      isTrue,
      reason: vault.lastError ?? '',
    );
    expect(File(path).existsSync(), isTrue);
    vault.close();

    final reopened = VaultController();
    expect(await reopened.open(path, 'pw-for-mkdir'), isTrue);
    reopened.close();

    dir.deleteSync(recursive: true);
  });
}
