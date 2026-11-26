import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/sync_lan.dart';
import 'package:passbook/core/vault_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 协议层的判据：真起一个 HTTP 端点、真跑一次客户端。合并逻辑在
/// `sync_merge_test.dart` 里测过了，这里只问「两台进程能不能对上话」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // flutter_test 默认把 HttpClient 换成「一律 400」的桩；这个 suite 要验真实
    // 协议（同机起端点、真发请求），所以关掉它。每个测试文件是独立 isolate，
    // 不会影响别的 suite。
    HttpOverrides.global = null;
  });

  Future<(VaultController, VaultController, Directory)> pair() async {
    final dir = Directory.systemTemp.createTempSync('passbook_lan');
    final pa = '${dir.path}${Platform.pathSeparator}a.kdbx';
    final pb = '${dir.path}${Platform.pathSeparator}b.kdbx';

    final a = VaultController();
    expect(await a.createAt(pa, 'lan-pw'), isTrue, reason: a.lastError ?? '');
    await a.save();
    File(pa).copySync(pb);

    final b = VaultController();
    expect(await b.open(pb, 'lan-pw'), isTrue, reason: b.lastError ?? '');
    return (a, b, dir);
  }

  Set<String> titlesOf(VaultController v) => {
    for (final e in v.allEntries) v.fieldOf(e, 'Title'),
  };

  test('真起端点：两端各加一条，同步后都到对方', () async {
    final (a, b, dir) = await pair();

    final ea = a.addEntry();
    a.updateField(ea, 'Title', 'A 加的');
    await a.save();

    final eb = b.addEntry();
    b.updateField(eb, 'Title', 'B 加的');
    await b.save();

    final server = LanSync(a);
    final code = await server.start();
    addTearDown(server.stop);

    final client = LanSync(b);
    final beforeA = titlesOf(a);
    final beforeB = titlesOf(b);
    final result = await client.pullFrom(
      host: '127.0.0.1',
      port: server.port!,
      code: code,
    );

    // B 拉到 A 的那条
    expect(
      result.added,
      1,
      reason: '合并前 A=$beforeA B=$beforeB · 结果=${result.summary} · 合并后 B=${titlesOf(b)}',
    );
    expect(titlesOf(b), containsAll(['A 加的', 'B 加的']));
    // A 收到了 B 推出回来的合并结果，也应有 B 的那条
    expect(titlesOf(a), containsAll(['A 加的', 'B 加的']));
    expect(titlesOf(a), titlesOf(b));

    a.close();
    b.close();
    dir.deleteSync(recursive: true);
  });

  test('配对码不对就被挡在门外', () async {
    final (a, b, dir) = await pair();
    final server = LanSync(a);
    final code = await server.start();
    addTearDown(server.stop);

    final wrong = code == '000000' ? '111111' : '000000';
    final client = LanSync(b);

    await expectLater(
      client.pullFrom(host: '127.0.0.1', port: server.port!, code: wrong),
      throwsA(isA<LanSyncException>()),
    );

    a.close();
    b.close();
    dir.deleteSync(recursive: true);
  });

  test('用过一次之后配对码会换掉', () async {
    final (a, b, dir) = await pair();
    final server = LanSync(a);
    final first = await server.start();
    addTearDown(server.stop);

    final client = LanSync(b);
    await client.pullFrom(host: '127.0.0.1', port: server.port!, code: first);

    expect(server.code, isNot(first), reason: '一把钥匙只开一次门');

    a.close();
    b.close();
    dir.deleteSync(recursive: true);
  });

  test('线上走的是密文：导出的字节是 KDBX，且不含条目明文', () async {
    final (a, b, dir) = await pair();

    const marker = 'PLAINTEXT-MARKER-9f3a';
    final e = a.addEntry();
    a.updateField(e, 'Title', marker);
    await a.save();

    final bytes = await a.exportBytes();

    // KDBX 4 魔数：03 D9 A2 9A 67 FB 4B B5
    expect(
      bytes.sublist(0, 8),
      [0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5],
      reason: '同步传的必须是 KDBX 库文件本身，不是自己另编的明文格式',
    );

    final asText = String.fromCharCodes(bytes);
    expect(
      asText.contains(marker),
      isFalse,
      reason: '条目内容在线上必须是密文——明文出现在字节里说明哪里漏了',
    );

    a.close();
    b.close();
    dir.deleteSync(recursive: true);
  });

  test('对面是另一个空库：本机有内容也能一次同步对齐', () async {
    // 这是实测撞到的那一幕：手机记了 15 条，电脑是刚建的空库（另一个库，
    // 根分组 uuid 不同）。原来的规则在手机上直接报「不许顶掉」，人得自己
    // 跑到电脑那台反向操作一次——明明没有任何数据会丢。
    final dir = Directory.systemTemp.createTempSync('passbook_adopt_lan');
    final sep = Platform.pathSeparator;

    final phone = VaultController();
    final phonePath = '${dir.path}${sep}phone.kdbx';
    expect(await phone.createAt(phonePath, 'lan-pw'), isTrue,
        reason: phone.lastError ?? '');
    for (final t in ['微信', '邮箱', 'GitHub']) {
      final e = phone.addEntry();
      phone.updateField(e, 'Title', t);
    }
    await phone.save();

    final pc = VaultController();
    final pcPath = '${dir.path}${sep}pc.kdbx';
    expect(await pc.createAt(pcPath, 'lan-pw'), isTrue,
        reason: pc.lastError ?? '');
    expect(pc.allEntries, isEmpty);

    final server = LanSync(pc);
    final code = await server.start();
    final port = server.port!;
    addTearDown(() async {
      await server.stop();
      phone.close();
      pc.close();
      dir.deleteSync(recursive: true);
    });

    final result = await LanSync(phone).pullFrom(
      host: '127.0.0.1',
      port: port,
      code: code,
    );

    expect(result.added, 0, reason: '空库那头本来就没有东西可并进来');
    expect(titlesOf(phone).length, 3, reason: '本机的条目一条都不能少');
    expect(
      titlesOf(pc),
      containsAll(['微信', '邮箱', 'GitHub']),
      reason: '空库那台应当已经接管了本机的库',
    );
    expect(pc.allEntries.length, 3);
  });
}
