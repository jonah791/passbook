import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/password_gen.dart';

/// 生成的密码要被站点接受（四类字符齐全），也要能被主人抄对（无易混字符）。
void main() {
  group('PasswordGenerator', () {
    test('长度符合请求', () {
      expect(
        PasswordGenerator.generate().length,
        PasswordGenerator.defaultLength,
      );
      expect(PasswordGenerator.generate(length: 8).length, 8);
      expect(PasswordGenerator.generate(length: 64).length, 64);
    });

    test('四类字符各至少一个', () {
      for (var i = 0; i < 50; i++) {
        final pwd = PasswordGenerator.generate(length: 8);
        expect(pwd.contains(RegExp('[a-z]')), isTrue, reason: '缺小写：$pwd');
        expect(pwd.contains(RegExp('[A-Z]')), isTrue, reason: '缺大写：$pwd');
        expect(pwd.contains(RegExp('[2-9]')), isTrue, reason: '缺数字：$pwd');
        expect(
          pwd.contains(RegExp(r'[!@#$%^&*\-_=+?]')),
          isTrue,
          reason: '缺符号：$pwd',
        );
      }
    });

    test('不含肉眼易混字符', () {
      for (var i = 0; i < 50; i++) {
        final pwd = PasswordGenerator.generate(length: 100);
        for (final ch in ['0', 'O', '1', 'l', 'I']) {
          expect(pwd.contains(ch), isFalse, reason: '出现了易混字符 $ch：$pwd');
        }
      }
    });

    test('两次生成不相同', () {
      expect(PasswordGenerator.generate(), isNot(PasswordGenerator.generate()));
    });
  });
}
