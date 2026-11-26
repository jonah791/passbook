import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/vault_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 自动锁定的数据安全前提是「先 flush、再 close」这个顺序。
/// 这里连负样本一起测：证明 flush 那一步不是装饰。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('flushNow 之后 close，改动已经落盘', () async {
    final dir = Directory.systemTemp.createTempSync('passbook_flush');
    final path = '${dir.path}/v.kdbx';

    final vault = VaultController();
    expect(await vault.createAt(path, 'master-1'), isTrue);
    final entry = vault.addEntry();
    vault.updateField(entry, 'Title', '锁定前的内容');
    vault.scheduleSave();

    await vault.flushNow();
    vault.close();

    final reopened = VaultController();
    expect(await reopened.open(path, 'master-1'), isTrue);
    expect(reopened.allEntries.length, 1);
    expect(reopened.allEntries.first.fields['Title']?.text, '锁定前的内容');

    reopened.close();
    dir.deleteSync(recursive: true);
  });

  test('没 flush 就 close，改动确实会丢（所以锁定时必须先 flush）', () async {
    final dir = Directory.systemTemp.createTempSync('passbook_nush');
    final path = '${dir.path}/v.kdbx';

    final vault = VaultController();
    expect(await vault.createAt(path, 'master-2'), isTrue);
    final entry = vault.addEntry();
    await vault.save(); // 条目已落盘，标题此刻是空

    vault.updateField(entry, 'Title', '要丢的');
    vault.scheduleSave();
    vault.close(); // 故意跳过 flushNow

    final reopened = VaultController();
    expect(await reopened.open(path, 'master-2'), isTrue);
    expect(reopened.allEntries.length, 1);
    expect(reopened.allEntries.first.fields['Title']?.text, isEmpty);

    reopened.close();
    dir.deleteSync(recursive: true);
  });
}
