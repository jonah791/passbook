import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/update/installer.dart';

/// 跨语言的契约守卫。
///
/// 自动更新一半在 Dart、一半在 Android 清单/Kotlin 与 PowerShell 脚本里。
/// 那些文件不会被 `flutter analyze` 检查，改动它们时也没有编译器拦你——
/// 症状要等到「用户点安装，什么也没发生」才出现。这里把契约写成断言。
///
/// 注意：文件读取要发生在**测试体内部**（`test()` 里），不能在 group 声明期
/// 调 `expect`——那时还没有测试上下文，抛的是 OutsideTestException。
void main() {
  String read(String relative) {
    final file = File(relative);
    expect(file.existsSync(), isTrue, reason: '缺少 $relative');
    return file.readAsStringSync();
  }

  String manifest() => read('android/app/src/main/AndroidManifest.xml');
  String filePaths() => read('android/app/src/main/res/xml/file_paths.xml');
  String activity() =>
      read('android/app/src/main/kotlin/com/passbook/passbook/MainActivity.kt');
  String service() => read('lib/core/update/update_service.dart');
  String installer() => read('lib/core/update/installer.dart');

  group('Android 清单', () {
    test('声明了「安装未知应用」权限', () {
      expect(manifest(), contains('android.permission.REQUEST_INSTALL_PACKAGES'));
    });

    test('注册了 FileProvider，且 authority 用 applicationId 拼出来', () {
      final xml = manifest();
      expect(xml, contains('androidx.core.content.FileProvider'));
      expect(xml, contains(r'android:authorities="${applicationId}.updater"'));
      // 授予 URI 权限必须是 true，否则安装器读不到那个 content://
      expect(xml, contains('android:grantUriPermissions="true"'));
    });

    test('外联说明与实现一致：只去 GitHub（没有残留「不查更新」的旧注释）', () {
      final xml = manifest();
      expect(xml, contains('GitHub'));
      expect(
        xml.contains('不查更新'),
        isFalse,
        reason: '加了自动更新之后，旧注释就变成了谎言——过时的注释比没有更糟',
      );
    });
  });

  group('FileProvider 暴露面', () {
    test('只暴露缓存目录下的 updates/ 子目录', () {
      final xml = filePaths();
      expect(xml, contains('<cache-path'));
      expect(xml, contains('path="updates/"'));
      // 写宽成 path="." 等于把整个私有缓存对外开放
      expect(xml.contains('path="."'), isFalse);
    });

    test('Dart 侧的落点目录名与它一字不差', () {
      final code = service();
      // 目录名必须与 file_paths.xml 的 path="updates/" 对上，否则 FileProvider 拒绝授权
      expect(code, contains(r'Platform.pathSeparator}updates'));
      // Android 必须走 path_provider 的临时目录（= 应用缓存目录），
      // 用 Directory.systemTemp 在真机上未必是 cache，路径对不上 FileProvider 会抛异常。
      expect(code, contains('getTemporaryDirectory()'));
    });
  });

  group('Kotlin 侧', () {
    test('方法通道名与 Dart 侧一致', () {
      expect(activity(), contains('"passbook/updater"'));
      expect(installer(), contains("MethodChannel('passbook/updater')"));
      expect(activity(), contains('"installApk"'));
    });

    test('没开权限时把用户送到开关前，并如实返回 false', () {
      final kt = activity();
      expect(kt, contains('canRequestPackageInstalls'));
      expect(kt, contains('ACTION_MANAGE_UNKNOWN_APP_SOURCES'));
      expect(kt, contains('return false'));
    });

    test('用 FileProvider 生成 content:// 并授予读权限', () {
      final kt = activity();
      expect(kt, contains('FileProvider.getUriForFile'));
      expect(kt, contains(r'"${packageName}.updater"'));
      expect(kt, contains('FLAG_GRANT_READ_URI_PERMISSION'));
      expect(kt, contains('application/vnd.android.package-archive'));
    });
  });

  group('Windows 更新脚本', () {
    test('先等旧进程退出，再覆盖（不等就会撞上被锁的 exe）', () {
      final script = WindowsZipInstaller.scriptBody;
      expect(script, contains(r'Get-Process -Id $WaitPid'));
      expect(script, contains('Start-Sleep'));
    });

    test('解压到暂存目录再整体覆盖，不边下边解', () {
      final script = WindowsZipInstaller.scriptBody;
      expect(script, contains('Expand-Archive'));
      expect(script, contains('robocopy'));
      // robocopy 的 0–7 是成功，≥8 才是失败
      expect(script, contains(r'$rc -ge 8'));
    });

    test('失败要留日志（GUI 子进程没有控制台）', () {
      final script = WindowsZipInstaller.scriptBody;
      expect(script, contains('passbook-update.log'));
      expect(script, contains('exit 1'));
    });

    test('不用 Start-Process：环境里同时有 NO_PROXY 与 no_proxy 时它会直接崩', () {
      final script = WindowsZipInstaller.scriptBody;
      // 本机实测：Start-Process 复制环境变量时撞上大小写重复键，抛
      // 「Item has already been added. Key in dictionary: 'NO_PROXY'」。
      expect(script.contains('Start-Process'), isFalse);
      expect(script, contains(r'[System.Diagnostics.Process]::Start($ExePath)'));
      expect(script, contains(r'& robocopy.exe'));
      expect(script, contains(r'$LASTEXITCODE'));
    });

    test('替换完成后重新启动新版本', () {
      expect(WindowsZipInstaller.scriptBody, contains(r'::Start($ExePath)'));
    });
  });
}
