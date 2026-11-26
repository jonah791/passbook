import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'release.dart';
import 'semver.dart';

/// 一次检查的三种结局。
///
/// **「没有新版」与「检查失败」必须分开**：合并成一句「已是最新」会让断网
/// 的时候也显示「已是最新」——这正是本工程最怕的静默失败形状
/// （AGENTS.md「没有证据」与「证据是空」是两件事）。
enum UpdateCheckKind { upToDate, updateAvailable, failed }

class UpdateCheck {
  const UpdateCheck({
    required this.kind,
    this.current,
    this.latest,
    this.release,
    this.asset,
    this.message,
  });

  const UpdateCheck.failed(String reason, {this.current})
      : kind = UpdateCheckKind.failed,
        latest = null,
        release = null,
        asset = null,
        message = reason;

  final UpdateCheckKind kind;
  final SemVer? current;
  final SemVer? latest;
  final ReleaseInfo? release;
  final ReleaseAsset? asset;
  final String? message;

  bool get hasUpdate => kind == UpdateCheckKind.updateAvailable;
  bool get failed => kind == UpdateCheckKind.failed;
}

/// 校验失败/下载失败时抛这个，而不是返回 null —— 静默兜底会装上一个坏包。
class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 查发布 + 下产物 + 校验摘要。**不发任何请求给除了 GitHub 之外的地址**，
/// 也不带任何凭据（公开仓库的 API 匿名可读）。
class UpdateService {
  UpdateService({
    required this.currentVersion,
    UpdateTarget? target,
    HttpClient Function()? clientFactory,
    Uri? latestUri,
    this.timeout = const Duration(seconds: 15),
  })  : target = target ?? UpdateTarget.current,
        _latestUri = latestUri ?? kLatestReleaseUri,
        _clientFactory = clientFactory ?? HttpClient.new;

  final String currentVersion;
  final UpdateTarget? target;

  /// 只在测试里指向本地端点；生产固定是 [kLatestReleaseUri]。
  final Uri _latestUri;

  final Duration timeout;
  final HttpClient Function() _clientFactory;

  /// 检查最新正式版。GitHub 的 `releases/latest` 本身不含预发布版，
  /// 所以这里不需要额外的渠道过滤。
  Future<UpdateCheck> check() async {
    final current = SemVer.tryParse(currentVersion);
    if (current == null) {
      return UpdateCheck.failed('本机版本号读不出来（$currentVersion）', current: null);
    }
    final target = this.target;
    if (target == null) {
      return const UpdateCheck.failed('当前平台不支持自动更新（只做了 Windows 与 Android）');
    }

    final client = _clientFactory();
    try {
      client.connectionTimeout = timeout;
      final request = await client.getUrl(_latestUri).timeout(timeout);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'passbook/$currentVersion (+$kRepoUri)',
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join().timeout(timeout);

      if (response.statusCode != 200) {
        final hint = switch (response.statusCode) {
          404 => '仓库或发布还不存在',
          403 => 'GitHub 限制了请求频率，稍后再试',
          301 || 302 => '仓库地址变了（改过名或换过账号）',
          _ => 'HTTP ${response.statusCode}',
        };
        return UpdateCheck.failed('检查失败：$hint', current: current);
      }

      final release = ReleaseInfo.tryParse(jsonDecode(body));
      if (release == null) {
        return UpdateCheck.failed('检查失败：发布信息解析不出来（缺 tag_name）', current: current);
      }
      final latest = release.version;
      if (latest == null) {
        return UpdateCheck.failed(
          '检查失败：发布标签不是版本号（${release.tag}）',
          current: current,
        );
      }
      if (!latest.isNewerThan(current)) {
        return UpdateCheck(
          kind: UpdateCheckKind.upToDate,
          current: current,
          latest: latest,
          release: release,
        );
      }
      final asset = release.assetFor(target);
      if (asset == null) {
        return UpdateCheck.failed(
          '新版 ${release.tag} 里没有本机可用的产物（${target.artifactName}）',
          current: current,
        );
      }
      return UpdateCheck(
        kind: UpdateCheckKind.updateAvailable,
        current: current,
        latest: latest,
        release: release,
        asset: asset,
      );
    } on TimeoutException {
      return UpdateCheck.failed('检查失败：请求超时（${timeout.inSeconds} 秒）', current: current);
    } on SocketException catch (e) {
      return UpdateCheck.failed('检查失败：连不上 GitHub（${e.osError?.message ?? e.message}）', current: current);
    } on HandshakeException {
      return UpdateCheck.failed('检查失败：TLS 握手失败（代理或证书拦截？）', current: current);
    } on FormatException {
      return UpdateCheck.failed('检查失败：返回内容不是合法 JSON', current: current);
    } finally {
      client.close(force: true);
    }
  }

  /// 下载产物并校验 SHA256。
  ///
  /// **没有摘要就拒绝下载**：自动更新一个密码本，装上的二进制必须能被核对。
  /// 摘要来自两处——发布资产自带的 `digest`，或同发布里的 `SHA256SUMS.txt`。
  Future<File> download({
    required ReleaseInfo release,
    required ReleaseAsset asset,
    void Function(double progress)? onProgress,
  }) async {
    final expected = asset.sha256 ?? await _fetchChecksum(release, asset.name);
    if (expected == null) {
      throw UpdateException(
        '发布里没有 ${asset.name} 的 SHA256 摘要，拒绝自动安装；'
        '可以手动去 ${kRepoUri.toString()}/releases 下载。',
      );
    }
    if (asset.size > 0 && asset.size < 1024) {
      throw UpdateException('产物大小异常（${asset.size} B），不像是安装包');
    }

    final dir = await artifactDir();
    final file = File('${dir.path}${Platform.pathSeparator}${asset.name}');
    final client = _clientFactory();
    try {
      client.connectionTimeout = timeout;
      final request = await client.getUrl(asset.url).timeout(timeout);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'passbook/$currentVersion (+$kRepoUri)',
      );
      request.followRedirects = true;
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        throw UpdateException('下载失败：HTTP ${response.statusCode}');
      }
      final total = response.contentLength > 0 ? response.contentLength : asset.size;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(timeout)) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            onProgress?.call((received / total).clamp(0.0, 1.0));
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (received == 0) throw UpdateException('下载到 0 字节');

      final actual = await sha256OfFile(file);
      if (actual != expected.toLowerCase()) {
        await file.delete();
        throw UpdateException(
          'SHA256 不匹配：期望 ${expected.substring(0, 12)}…，实际 ${actual.substring(0, 12)}…'
          '（产物可能被替换或下载被截断）',
        );
      }
      return file;
    } finally {
      client.close(force: true);
    }
  }

  /// 产物落点。Android 必须落在**应用缓存目录**下，且子目录名与
  /// `res/xml/file_paths.xml` 里暴露的 `updates/` 一字不差——
  /// FileProvider 只放行那一个子目录，路径对不上就抛 IllegalArgumentException。
  static Future<Directory> artifactDir() async {
    final Directory base;
    if (Platform.isAndroid) {
      base = await getTemporaryDirectory();
    } else {
      base = Directory.systemTemp;
    }
    final dir = Directory('${base.path}${Platform.pathSeparator}updates');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<String?> _fetchChecksum(ReleaseInfo release, String assetName) async {    final sums = release.assetNamed(kChecksumFileName);
    if (sums == null) return null;
    final client = _clientFactory();
    try {
      client.connectionTimeout = timeout;
      final request = await client.getUrl(sums.url).timeout(timeout);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'passbook/$currentVersion (+$kRepoUri)',
      );
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      return sha256FromChecksums(body, assetName);
    } on Exception {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 从 `sha256sum` 格式的正文里取某文件的摘要；取不到返回 null。
  static String? sha256FromChecksums(String body, String fileName) {
    final pattern = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$', multiLine: true);
    for (final match in pattern.allMatches(body)) {
      if (match[2] == fileName) return match[1]!.toLowerCase();
    }
    return null;
  }

  static Future<String> sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}
