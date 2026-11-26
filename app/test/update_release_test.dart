import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/update/release.dart';

/// 发布信息的解析判据：这份 JSON 的形状来自 GitHub Releases API，
/// 一旦解析错，症状是「明明有新版却说已是最新」或反过来。
void main() {
  Map<String, Object?> releaseJson({
    String tag = 'v1.2.0',
    List<Map<String, Object?>>? assets,
    String? digest,
  }) {
    final windows = <String, Object?>{
      'name': 'passbook-windows-x64.zip',
      'size': 31457280,
      'browser_download_url':
          'https://github.com/jonah791/passbook/releases/download/$tag/passbook-windows-x64.zip',
    };
    if (digest != null) windows['digest'] = digest;
    return {
      'tag_name': tag,
      'name': 'passbook $tag',
      'body': '修复若干问题',
      'html_url': 'https://github.com/jonah791/passbook/releases/tag/$tag',
      'assets': assets ??
          [
            windows,
            {
              'name': 'passbook-android.apk',
              'size': 12582912,
              'browser_download_url':
                  'https://github.com/jonah791/passbook/releases/download/$tag/passbook-android.apk',
            },
            {
              'name': 'SHA256SUMS.txt',
              'size': 180,
              'browser_download_url':
                  'https://github.com/jonah791/passbook/releases/download/$tag/SHA256SUMS.txt',
            },
          ],
    };
  }

  group('ReleaseInfo 解析', () {
    test('tag / 名称 / 说明 / 产物全部取到', () {
      final info = ReleaseInfo.tryParse(releaseJson());
      expect(info, isNotNull);
      expect(info!.tag, 'v1.2.0');
      expect(info.version?.toString(), '1.2.0');
      expect(info.title, 'passbook v1.2.0');
      expect(info.notes, '修复若干问题');
      expect(info.assets.length, 3);
      expect(info.htmlUrl.toString(), contains('/releases/tag/v1.2.0'));
    });

    test('缺 tag_name 判为解析失败（而不是当成空发布）', () {
      expect(ReleaseInfo.tryParse({'name': 'x', 'assets': []}), isNull);
      expect(ReleaseInfo.tryParse({'tag_name': '', 'assets': []}), isNull);
      expect(ReleaseInfo.tryParse('not a map'), isNull);
      expect(ReleaseInfo.tryParse(null), isNull);
    });

    test('资产缺名字或缺下载地址时跳过它，不整份作废', () {
      final info = ReleaseInfo.tryParse({
        'tag_name': 'v1.0.1',
        'assets': [
          {'name': 'no-url'},
          {'browser_download_url': 'https://example.com/x'},
          {
            'name': 'passbook-android.apk',
            'size': 100,
            'browser_download_url': 'https://example.com/a.apk',
          },
        ],
      });
      expect(info!.assets.length, 1);
      expect(info.assets.single.name, 'passbook-android.apk');
    });

    test('digest 字段解析成小写 sha256；不是 sha256 就忽略', () {
      final ok = ReleaseInfo.tryParse(
        releaseJson(digest: 'sha256:${'A' * 64}'),
      );
      expect(ok!.assetNamed('passbook-windows-x64.zip')!.sha256, 'a' * 64);

      final ignored = ReleaseInfo.tryParse(releaseJson(digest: 'sha512:${'a' * 128}'));
      expect(ignored!.assetNamed('passbook-windows-x64.zip')!.sha256, isNull);
    });
  });

  group('产物选择', () {
    test('按契约名精确命中', () {
      final info = ReleaseInfo.tryParse(releaseJson())!;
      expect(
        info.assetFor(UpdateTarget.windows)?.name,
        'passbook-windows-x64.zip',
      );
      expect(info.assetFor(UpdateTarget.android)?.name, 'passbook-android.apk');
    });

    test('契约名没命中时按扩展名兜底——但只接受唯一命中', () {
      final single = ReleaseInfo.tryParse({
        'tag_name': 'v2.0.0',
        'assets': [
          {
            'name': 'Passbook.APK',
            'size': 100,
            'browser_download_url': 'https://example.com/x.apk',
          },
        ],
      })!;
      expect(single.assetFor(UpdateTarget.android)?.name, 'Passbook.APK');

      // 两个候选里挑一个等于抛硬币：宁可返回 null 让上层报「没有可用产物」。
      final ambiguous = ReleaseInfo.tryParse({
        'tag_name': 'v2.0.0',
        'assets': [
          {'name': 'a.apk', 'size': 1, 'browser_download_url': 'https://example.com/a.apk'},
          {'name': 'b.apk', 'size': 1, 'browser_download_url': 'https://example.com/b.apk'},
        ],
      })!;
      expect(ambiguous.assetFor(UpdateTarget.android), isNull);
    });

    test('发布里根本没有本端产物 ⇒ null（上层会如实报缺产物）', () {
      final info = ReleaseInfo.tryParse({
        'tag_name': 'v2.0.0',
        'assets': [
          {
            'name': 'source.tar.gz',
            'size': 1,
            'browser_download_url': 'https://example.com/s.tar.gz',
          },
        ],
      })!;
      expect(info.assetFor(UpdateTarget.windows), isNull);
    });
  });

  test('仓库坐标可被 --dart-define 换掉（默认指向本项目）', () {
    // 默认值必须与发布脚本上传的目标一致，否则「检查更新」永远查的是别人的仓库。
    expect(kRepoSlug, 'jonah791/passbook');
    expect(kRepoUri.toString(), 'https://github.com/jonah791/passbook');
    expect(kLatestReleaseUri.toString(),
        'https://api.github.com/repos/jonah791/passbook/releases/latest');
    expect(const JsonEncoder().convert({'slug': kRepoSlug}), contains('passbook'));
  });
}
