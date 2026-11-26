import 'dart:io';

import 'package:passbook/core/update/installer.dart';

/// 把随应用发布的 Windows 更新脚本原样落盘，供离线冒烟测试用。
///
/// 为什么要这样而不是在测试里复制一份脚本：复制出来的那份**不是打包进应用的那一份**，
/// 测它就等于测另一个程序。这里倒出来的字节与运行时写进 %TEMP% 的完全一致。
///
/// 跑法：dart run tool/update_script_dump.dart <输出路径>
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/update_script_dump.dart <输出路径>');
    exit(2);
  }
  final out = File(args.first);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(WindowsZipInstaller.scriptBody);
  stdout.writeln('WROTE=${out.path} bytes=${out.lengthSync()}');
}
