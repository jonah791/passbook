import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kpasslib/kpasslib.dart';

/// 判据 1：新建 → 保存 → 重新打开，条目与密码一致；文件是标准 KDBX 签名。
void main() {
  test('KDBX create, save, reopen round trip', () async {
    final dir = Directory.systemTemp.createTempSync('passbook_test');
    final path = '${dir.path}/test.kdbx';
    final credentials = KdbxCredentials(
      password: ProtectedData.fromString('test-password-123'),
    );

    final db = KdbxDatabase.create(credentials: credentials, name: 'Test');
    final group = db.createGroup(parent: db.root, name: '默认分组');
    final entry = db.createEntry(parent: group);
    entry.fields.addAll({
      'Title': KdbxTextField.fromText(text: '示例'),
      'UserName': KdbxTextField.fromText(text: 'alice'),
      'Password': KdbxTextField.fromText(text: 's3cret', protected: true),
    });

    final bytes = await db.save();
    await File(path).writeAsBytes(bytes, flush: true);

    // KDBX 4 签名：0x03D9A29A
    expect(bytes.length, greaterThan(4));
    expect(bytes[0], 0x03);
    expect(bytes[1], 0xD9);
    expect(bytes[2], 0xA2);
    expect(bytes[3], 0x9A);

    final reopened = await KdbxDatabase.fromBytes(
      data: await File(path).readAsBytes(),
      credentials: credentials,
    );
    final entries = reopened.root.allEntries;
    expect(entries.length, 1);
    expect(entries.first.fields['Title']?.text, '示例');
    expect(entries.first.fields['UserName']?.text, 'alice');
    expect(entries.first.fields['Password']?.text, 's3cret');

    dir.deleteSync(recursive: true);
  });

  test('wrong password is rejected', () async {
    final dir = Directory.systemTemp.createTempSync('passbook_test2');
    final path = '${dir.path}/test.kdbx';
    final credentials = KdbxCredentials(
      password: ProtectedData.fromString('right-password'),
    );
    final db = KdbxDatabase.create(credentials: credentials, name: 'Test');
    await File(path).writeAsBytes(await db.save(), flush: true);

    await expectLater(
      KdbxDatabase.fromBytes(
        data: await File(path).readAsBytes(),
        credentials: KdbxCredentials(
          password: ProtectedData.fromString('wrong-password'),
        ),
      ),
      throwsA(anything),
    );

    dir.deleteSync(recursive: true);
  });
}
