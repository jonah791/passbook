import 'dart:io';

import 'semver.dart';

/// 发布仓库。fork 的人用 `--dart-define=PASSBOOK_REPO=owner/repo` 换掉，
/// 这样自动更新不需要改一行代码就能指向自己的发布。
const String kRepoSlug = String.fromEnvironment(
  'PASSBOOK_REPO',
  defaultValue: 'jonah791/passbook',
);

final Uri kRepoUri = Uri.parse('https://github.com/$kRepoSlug');
final Uri kLatestReleaseUri =
    Uri.parse('https://api.github.com/repos/$kRepoSlug/releases/latest');

/// 发布里附带的摘要清单（`sha256sum` 同格式：`<64 hex>  <文件名>` 每行一条）。
const String kChecksumFileName = 'SHA256SUMS.txt';

/// 自动更新的目标端。产物文件名是发布脚本与客户端之间的契约，
/// 改名要两边一起改（`scripts/release.ps1`）。
enum UpdateTarget {
  windows('passbook-windows-x64.zip', '.zip'),
  android('passbook-android.apk', '.apk');

  const UpdateTarget(this.artifactName, this.extension);

  final String artifactName;
  final String extension;

  /// 当前进程能自动更新的端；不支持时返回 null（由调用方如实报「不支持」）。
  static UpdateTarget? get current {
    if (Platform.isWindows) return UpdateTarget.windows;
    if (Platform.isAndroid) return UpdateTarget.android;
    return null;
  }
}

/// 发布里的一个可下载文件。
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.size,
    required this.url,
    this.sha256,
  });

  final String name;
  final int size;
  final Uri url;

  /// GitHub 的 `digest` 字段（`sha256:...`）。旧发布没有这个字段时为 null，
  /// 那就得靠 [kChecksumFileName] 兜底——两条都没有就**不许装**。
  final String? sha256;

  static ReleaseAsset? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final url = raw['browser_download_url'];
    if (name is! String || name.isEmpty || url is! String || url.isEmpty) {
      return null;
    }
    final size = raw['size'];
    final digest = raw['digest'];
    String? sha;
    if (digest is String && digest.startsWith('sha256:')) {
      final value = digest.substring('sha256:'.length).trim().toLowerCase();
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) sha = value;
    }
    return ReleaseAsset(
      name: name,
      size: size is int ? size : 0,
      url: Uri.parse(url),
      sha256: sha,
    );
  }

  @override
  String toString() => 'ReleaseAsset($name, $size B)';
}

/// 一次发布的全部信息（GitHub Releases API 的子集）。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.title,
    required this.notes,
    required this.htmlUrl,
    required this.assets,
  });

  final String tag;
  final String title;
  final String notes;
  final Uri htmlUrl;
  final List<ReleaseAsset> assets;

  SemVer? get version => SemVer.tryParse(tag);

  ReleaseAsset? assetNamed(String name) {
    for (final a in assets) {
      if (a.name == name) return a;
    }
    return null;
  }

  /// 找本端要装的那个产物：先按契约名精确命中，没命中再按扩展名——
  /// 但**只在唯一命中时**才用（两个候选里挑一个等于抛硬币）。
  ReleaseAsset? assetFor(UpdateTarget target) {
    final exact = assetNamed(target.artifactName);
    if (exact != null) return exact;
    final byExt = assets
        .where((a) => a.name.toLowerCase().endsWith(target.extension))
        .toList(growable: false);
    return byExt.length == 1 ? byExt.first : null;
  }

  static ReleaseInfo? tryParse(Object? raw) {    if (raw is! Map) return null;
    final tag = raw['tag_name'];
    if (tag is! String || tag.isEmpty) return null;
    final assets = <ReleaseAsset>[];
    final rawAssets = raw['assets'];
    if (rawAssets is List) {
      for (final item in rawAssets) {
        final asset = ReleaseAsset.tryParse(item);
        if (asset != null) assets.add(asset);
      }
    }
    final name = raw['name'];
    final body = raw['body'];
    final htmlUrl = raw['html_url'];
    return ReleaseInfo(
      tag: tag,
      title: name is String && name.isNotEmpty ? name : tag,
      notes: body is String ? body : '',
      htmlUrl: Uri.parse(
        htmlUrl is String && htmlUrl.isNotEmpty ? htmlUrl : kRepoUri.toString(),
      ),
      assets: assets,
    );
  }

  @override
  String toString() => 'ReleaseInfo($tag, ${assets.length} 个产物)';

  /// 从发布页的重定向地址里取标签：`…/releases/tag/v1.2.3` → `v1.2.3`。
  ///
  /// 这条路存在的理由：GitHub 的 **API** 对匿名请求是 60 次/小时/**按出口 IP** 计，
  /// 而 `releases/latest` 这个**网页**地址会 302 到当前最新 tag，不占 API 配额。
  /// 出口在共享代理后面时（本机实测撞到 60/60），API 会一直 403，而这条路照样能用。
  static String? tagFromReleaseLocation(Uri location) {
    final segments = location.pathSegments;
    final index = segments.indexOf('tag');
    if (index < 0 || index + 1 >= segments.length) return null;
    final tag = segments[index + 1];
    return tag.isEmpty ? null : tag;
  }

  /// 只有标签、没有 API 元数据时，按**产物命名约定**拼一份等价信息。
  ///
  /// 代价如实写在这里：拿不到发布说明，也拿不到产物大小（size=0，下载时按响应头算进度）；
  /// 摘要必须靠同目录的 `SHA256SUMS.txt`——所以那个文件是发布契约的一部分，不许省。
  static ReleaseInfo forTagFromRepo(Uri repoPage, String tag) {
    final base = repoPage.toString().replaceAll(RegExp(r'/+$'), '');
    Uri downloadUrl(String name) =>
        Uri.parse('$base/releases/download/$tag/$name');
    return ReleaseInfo(
      tag: tag,
      title: tag,
      notes: '',
      htmlUrl: Uri.parse('$base/releases/tag/$tag'),
      assets: [
        for (final target in UpdateTarget.values)
          ReleaseAsset(
            name: target.artifactName,
            size: 0,
            url: downloadUrl(target.artifactName),
          ),
        ReleaseAsset(
          name: kChecksumFileName,
          size: 0,
          url: downloadUrl(kChecksumFileName),
        ),
      ],
    );
  }
}
