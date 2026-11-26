import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'vault_controller.dart';

/// 局域网同步：一端开端点等，另一端拉库 → 本地合并 → 把合并结果推回去。
///
/// **线上永远只走 KDBX 密文**——内容本来就是加密的，传输层不必再加一层，
/// 真正要防的是「连错设备」，所以有一次性配对码。
///
/// 合并用库自带的 `KdbxDatabase.merge`（2P-set + 墓碑），不手写 CRDT。
///
/// 为什么推回的是「合并结果」而不是「对端的原始库」：
/// 推送之前本地可能又改了几笔，直接覆盖会把它们冲掉；让对方再 merge 一次
/// 是幂等的，安全得多。
class LanSync {
  LanSync(this.vault);

  final VaultController vault;

  /// 对端把合并结果推来时触发，界面据此刷新列表。
  void Function(MergeResult result)? onMerged;

  HttpServer? _server;
  String _code = '';
  Timer? _rotateTimer;
  Future<void> _queue = Future<void>.value();

  static const _maxBody = 64 * 1024 * 1024;

  bool get serving => _server != null;
  int? get port => _server?.port;
  String? get code => serving ? _code : null;

  /// 本机在局域网里的 IPv4（不含回环）。空列表 = 没连局域网。
  static Future<List<String>> localIPv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return [
        for (final i in interfaces)
          for (final a in i.addresses)
            if (!a.isLoopback) a.address,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 开始等对端，返回本次配对码。端口由系统分配，避免撞车。
  Future<String> start() async {
    await stop();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _code = _newCode();
    unawaited(_accept(_server!));
    return _code;
  }

  Future<void> stop() async {
    _rotateTimer?.cancel();
    _rotateTimer = null;
    final server = _server;
    _server = null;
    _code = '';
    await server?.close(force: true);
  }

  String _newCode() {
    final rng = Random.secure();
    return List.generate(6, (_) => rng.nextInt(10)).join();
  }

  Future<void> _accept(HttpServer server) async {
    await for (final req in server) {
      unawaited(_handleSerial(req));
    }
  }

  /// 串行化：两个请求同时进来会同时改库，后一个会把前一个的结果覆盖。
  Future<void> _handleSerial(HttpRequest req) {
    final done = _queue.then((_) => _handle(req));
    _queue = done.then((_) {}, onError: (_) {});
    return done;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.uri.path != '/vault') {
        return _reply(req, HttpStatus.notFound, '没有这个地址');
      }
      if (req.uri.queryParameters['code'] != _code) {
        return _reply(req, HttpStatus.forbidden, '配对码不对');
      }
      switch (req.method) {
        case 'GET':
          final bytes = await vault.exportBytes();
          req.response.headers.contentType = ContentType.binary;
          req.response.add(bytes);
          await req.response.close();
        case 'POST':
          final body = await _readBody(req);
          final result = await vault.mergeRemote(body);
          // 用过的码立刻作废：同一把钥匙不开两次门。
          _code = _newCode();
          onMerged?.call(result);
          req.response.statusCode = HttpStatus.noContent;
          await req.response.close();
        default:
          _reply(req, HttpStatus.methodNotAllowed, '只支持 GET / POST');
      }
    } catch (e) {
      _reply(req, HttpStatus.internalServerError, '$e');
    }
  }

  Future<Uint8List> _readBody(HttpRequest req) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in req) {
      builder.add(chunk);
      if (builder.length > _maxBody) {
        throw const LanSyncException('对端发来的内容太大');
      }
    }
    return builder.takeBytes();
  }

  void _reply(HttpRequest req, int status, String message) {
    try {
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.text;
      req.response.write(message);
      unawaited(req.response.close());
    } catch (_) {
      // 对方已断开，没什么可做的。
    }
  }

  /// 连对端：拉它的库 → 本地合并 → 把合并结果推回去。
  Future<MergeResult> pullFrom({
    required String host,
    required int port,
    required String code,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final uri = Uri.parse(
      'http://$host:$port/vault?code=${Uri.encodeQueryComponent(code)}',
    );
    try {
      final getRes = await (await client.getUrl(
        uri,
      )).close().timeout(const Duration(seconds: 20));
      if (getRes.statusCode != HttpStatus.ok) {
        final why = await getRes.transform(utf8.decoder).join();
        throw LanSyncException('对方不让拉（${getRes.statusCode}）：$why');
      }
      final remote = await consolidateHttpClientResponseBytes(getRes);
      final result = await vault.mergeRemote(remote);

      final merged = await vault.exportBytes();
      final postReq = await client.postUrl(uri);
      postReq.headers.contentType = ContentType.binary;
      postReq.add(merged);
      final postRes = await postReq.close().timeout(
        const Duration(seconds: 30),
      );
      await postRes.drain<void>();
      if (postRes.statusCode != HttpStatus.noContent) {
        throw LanSyncException('合并结果没被接受（${postRes.statusCode}）');
      }
      return result;
    } finally {
      client.close(force: true);
    }
  }
}

class LanSyncException implements Exception {
  const LanSyncException(this.message);
  final String message;

  @override
  String toString() => message;
}
