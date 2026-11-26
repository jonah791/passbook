import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/update/release.dart';
import 'package:passbook/core/update/update_service.dart';

/// 这套测试用一个**真的本地 HTTP 服务**当 GitHub，而不是 mock 掉 HttpClient。
///
/// 理由：自动更新的失败点全在真实链路上（状态码、分块下载、摘要比对），
/// 把 HttpClient 换成假对象会把这些一并测掉——测出来的是「假对象说得对」。
///
/// ⚠ 这个文件**不初始化 TestWidgetsFlutterBinding**：一旦初始化，
/// flutter_test 会把所有 HTTP 请求拦成 400，本地服务永远收不到请求。
/// 需要 binding 的部分（SharedPreferences 节流）在 update_throttle_test.dart。
void main() {
  final payload = List<int>.generate(4096, (i) => (i * 37) % 256);
  final goodSha = sha256.convert(payload).toString();

  late HttpServer server;
  late String checksumBody;
  var latestHits = 0;
  var tag = 'v9.9.9';

  setUp(() async {
    tag = 'v9.9.9';
    latestHits = 0;
    checksumBody = '$goodSha  passbook-android.apk\n';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final base = 'http://127.0.0.1:${server.port}';
      final response = request.response;
      switch (request.uri.path) {
        case '/releases/latest':
          latestHits++;
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({
            'tag_name': tag,
            'name': 'passbook $tag',
            'body': '测试发布说明',
            'html_url': '$base/releases/tag/$tag',
            'assets': [
              {
                'name': 'passbook-android.apk',
                'size': payload.length,
                'browser_download_url': '$base/passbook-android.apk',
              },
              {
                'name': 'SHA256SUMS.txt',
                'size': checksumBody.length,
                'browser_download_url': '$base/SHA256SUMS.txt',
              },
            ],
          }));
          break;
        case '/passbook-android.apk':
          response.add(payload);
          break;
        case '/SHA256SUMS.txt':
          response.write(checksumBody);
          break;
        default:
          response.statusCode = 404;
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  UpdateService buildService({String version = '1.0.0', String path = '/releases/latest'}) {
    return UpdateService(
      currentVersion: version,
      target: UpdateTarget.android,
      latestUri: Uri.parse('http://127.0.0.1:${server.port}$path'),
      timeout: const Duration(seconds: 5),
    );
  }

  group('检查更新', () {
    test('有更高版本时给出可安装的产物', () async {
      final result = await buildService().check();
      expect(result.kind, UpdateCheckKind.updateAvailable);
      expect(result.latest?.toString(), '9.9.9');
      expect(result.asset?.name, 'passbook-android.apk');
      expect(result.asset?.size, payload.length);
      expect(latestHits, 1);
    });

    test('本机已是最新时如实说 upToDate（不是 failed）', () async {
      final result = await buildService(version: '9.9.9').check();
      expect(result.kind, UpdateCheckKind.upToDate);
      expect(result.latest?.toString(), '9.9.9');
    });

    test('本机版本更高（开发中的构建）也算最新', () async {
      final result = await buildService(version: '10.0.0').check();
      expect(result.kind, UpdateCheckKind.upToDate);
    });

    test('HTTP 404 是 failed，不是「已是最新」', () async {
      final result = await buildService(path: '/nope').check();
      expect(result.kind, UpdateCheckKind.failed);
      expect(result.message, contains('还不存在'));
    });

    test('tag 不是版本号时明确报错', () async {
      tag = 'nightly-20261126';
      final result = await buildService().check();
      expect(result.kind, UpdateCheckKind.failed);
      expect(result.message, contains('不是版本号'));
    });

    test('本机版本号读不出来时拒绝判断', () async {
      final result = await buildService(version: 'unknown').check();
      expect(result.kind, UpdateCheckKind.failed);
      expect(result.message, contains('版本号'));
    });

    test('连不上时给可读的原因，而不是抛异常给界面', () async {
      final service = UpdateService(
        currentVersion: '1.0.0',
        target: UpdateTarget.android,
        // 1 号端口：本机几乎不可能有服务在听
        latestUri: Uri.parse('http://127.0.0.1:1/releases/latest'),
        timeout: const Duration(seconds: 2),
      );
      final result = await service.check();
      expect(result.kind, UpdateCheckKind.failed);
      expect(result.message, isNotEmpty);
    });
  });

  group('下载与校验', () {
    test('下载到本地、字节一致、摘要在 SHA256SUMS.txt 里', () async {
      final service = buildService();
      final result = await service.check();
      expect(result.kind, UpdateCheckKind.updateAvailable);
      var lastProgress = 0.0;
      final file = await service.download(
        release: result.release!,
        asset: result.asset!,
        onProgress: (value) => lastProgress = value,
      );
      expect(await file.readAsBytes(), payload);
      expect(file.path, endsWith('passbook-android.apk'));
      expect(lastProgress, 1.0);
      await file.delete();
    });

    test('摘要不匹配 ⇒ 拒绝安装，且把下载的坏包删掉', () async {
      checksumBody = '${'0' * 64}  passbook-android.apk\n';
      final service = buildService();
      final result = await service.check();
      await expectLater(
        service.download(release: result.release!, asset: result.asset!),
        throwsA(isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('SHA256 不匹配'),
        )),
      );
      final leftovers = await UpdateService.artifactDir();
      expect(
        leftovers
            .listSync()
            .whereType<File>()
            .any((f) => f.path.endsWith('passbook-android.apk')),
        isFalse,
        reason: '校验失败的包不能留在磁盘上——下次会被当成已下载的更新',
      );
    });

    test('发布里没有摘要 ⇒ 拒绝下载（密码本不接受未经核对的二进制）', () async {
      checksumBody = '';
      final service = buildService();
      final result = await service.check();
      await expectLater(
        service.download(release: result.release!, asset: result.asset!),
        throwsA(isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('拒绝自动安装'),
        )),
      );
    });

    test('产物太小（不像安装包）时不下载', () async {
      final service = buildService();
      final result = await service.check();
      final tiny = ReleaseAsset(
        name: result.asset!.name,
        size: 12,
        url: result.asset!.url,
        sha256: goodSha,
      );
      await expectLater(
        service.download(release: result.release!, asset: tiny),
        throwsA(isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('大小异常'),
        )),
      );
    });
  });

  group('sha256sum 格式解析', () {
    test('两种分隔写法都认（空格与星号）', () {
      final body = '${'a' * 64}  one.apk\n${'b' * 64} *two.apk\n';
      expect(UpdateService.sha256FromChecksums(body, 'one.apk'), 'a' * 64);
      expect(UpdateService.sha256FromChecksums(body, 'two.apk'), 'b' * 64);
      expect(UpdateService.sha256FromChecksums(body, 'three.apk'), isNull);
    });

    test('大写摘要归一成小写；长度不对的行不当摘要', () {
      final body = '${'A' * 64}  x.apk\n${'c' * 63}  y.apk\n';
      expect(UpdateService.sha256FromChecksums(body, 'x.apk'), 'a' * 64);
      expect(UpdateService.sha256FromChecksums(body, 'y.apk'), isNull);
    });
  });
}
