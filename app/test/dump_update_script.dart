import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/update/installer.dart';

/// 把**随应用发布的那一份** Windows 更新脚本原样落盘，供离线冒烟测试用。
///
/// 为什么要这样而不是在冒烟脚本里复制一份：复制出来的那份不是打包进应用的那一份，
/// 测它就等于测另一个程序。这里倒出来的字节与运行时写进 %TEMP% 的完全一致。
///
/// 跑法（需要 Flutter SDK，裸 dart run 编译不了 flutter 依赖）：
///   PASSBOOK_SCRIPT_OUT=E:\alice\.tmp\upd\install.ps1 flutter test test/dump_update_script.dart
void main() {
  test('导出更新脚本', () {
    final out = Platform.environment['PASSBOOK_SCRIPT_OUT'];
    expect(out, isNotNull, reason: '需要环境变量 PASSBOOK_SCRIPT_OUT');
    final file = File(out!);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(WindowsZipInstaller.scriptBody);
    stdout.writeln('WROTE=${file.path} bytes=${file.lengthSync()}');
    expect(file.lengthSync(), greaterThan(200));
  });
}
