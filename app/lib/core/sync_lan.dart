import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'merge_result.dart';
import 'vault_bridge.dart';

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
///
/// 这一层**不依赖 Flutter**（只用 `dart:io`）：同一份协议既跑在应用里，
/// 也跑在命令行对端（`tool/lan_peer.dart`）里，跨进程联调才可能。
class LanSync {
  LanSync(this.vault);

  final VaultBridge vault;

  /// 对端把合并结果推来时触发，界面据此刷新列表。
  void Function(MergeResult result)? onMerged;

  HttpServer? _server;
  RawDatagramSocket? _discovery;
  String _code = '';
  Timer? _rotateTimer;
  Future<void> _queue = Future<void>.value();

  static const _maxBody = 64 * 1024 * 1024;

  bool get serving => _server != null;
  int? get port => _server?.port;
  String? get code => serving ? _code : null;

  /// 本机在局域网里的 IPv4（不含回环）。
  ///
  /// **虚拟网卡的地址要剔掉。** 装了 WSL 的 Windows 会多出一块
  /// `vEthernet (WSL)`，地址常见 172.19.x.x，而它排得比真实网卡还前——
  /// 显示给用户之后，另一台设备照着它连，只会连到别的东西（实测拿回了
  /// 代理的 502）。这类地址不是「局域网地址」，它对别的设备不存在。
  ///
  /// 剔干净时把虚拟的也还回去：宁可显示一个可能连不到的地址，也不要让
  /// 「这台设备」区空着——空着会让人以为是功能坏了，而那时人至少能试。
  static Future<List<String>> localIPv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final real = <String>[];
      final virtual = <String>[];
      for (final i in interfaces) {
        final isVirtual = isVirtualNicName(i.name);
        for (final a in i.addresses) {
          if (a.isLoopback) continue;
          // 169.254.x.x 是「没拿到 DHCP 时自己编的」链路本地地址：同一根网线
          // 上的两台机器理论上能通，但接在路由器上的设备之间一律不通。把它
          // 摆在「另一台填这个」的位置上，等于给了一个必然失败的答案。
          if (isLinkLocalV4(a.address)) continue;
          (isVirtual ? virtual : real).add(a.address);
        }
      }
      return real.isNotEmpty ? real : virtual;
    } catch (_) {
      return const [];
    }
  }

  /// 看起来是不是链路本地地址（169.254.0.0/16）。
  static bool isLinkLocalV4(String address) => address.startsWith('169.254.');

  /// 虚拟网卡的适配器名。按名字判断不完美（各系统语言不同），所以这里只
  /// 用来**分先后**：一真网卡都找不着时仍然把虚拟的还回去。
  static final _virtualNicPattern = RegExp(
    r'vEthernet|WSL|Docker|VMware|VirtualBox|Hyper-V|Loopback|Tailscale|ZeroTier',
    caseSensitive: false,
  );

  /// 这个名字看起来是不是虚拟网卡。公开只为可测——真机上取网卡列表的结果
  /// 不可断言，能断言的是这条判断本身。
  static bool isVirtualNicName(String name) =>
      _virtualNicPattern.hasMatch(name);

  /// 开始等对端，返回本次配对码。端口由系统分配，避免撞车。
  ///
  /// [port] / [code] 只在测试与联调时显式给（要提前知道往哪连）；
  /// 正常使用一律不给，端口 0 = 系统分配、配对码随机生成。
  Future<String> start({int port = 0, String? code}) async {
    await stop();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _code = code ?? _newCode();
    unawaited(_accept(_server!));
    // 开着同步就等于「可以被找到」。UDP 起不来（端口被另一个实例占了、
    // 防火墙不放行）不该牵连 HTTP 那一侧——那样连扫码和手填都一起没了。
    try {
      _discovery = await LanDiscovery.announce(syncPort: _server!.port);
    } catch (_) {
      _discovery = null;
    }
    return _code;
  }

  Future<void> stop() async {
    _rotateTimer?.cancel();
    _rotateTimer = null;
    final discovery = _discovery;
    _discovery = null;
    discovery?.close();
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      // 显式声明直连，不交给任何代理。局域网同步打的是 192.168 这类内网
      // 地址，而代理对内网目标的回答通常是 502/503——那既不是对端说的话，
      // 也会让人以为是密码本坏了。默认值本来就是直连，这里写死是为了
      // 不被宿主环境（安卓的 ProxySelector、桌面上的系统代理插件）改掉。
      ..findProxy = ((_) => 'DIRECT');
    final uri = Uri.parse(
      'http://$host:$port/vault?code=${Uri.encodeQueryComponent(code)}',
    );
    try {
      final getRes = await (await client.getUrl(
        uri,
      )).close().timeout(const Duration(seconds: 20));
      if (getRes.statusCode != HttpStatus.ok) {
        final body = await getRes.transform(utf8.decoder).join();
        throw LanSyncException(
          '对方不让拉（${getRes.statusCode}）'
          '${explainSyncFailure(getRes.statusCode, body)}',
        );
      }
      final remote = await _readAll(getRes);
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
    } on SocketException catch (e) {
      throw LanSyncException(
        explainSocketFailure(e, host: host, port: port),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 把响应体读成字节。  ///
  /// 不用 `flutter/foundation` 的 `consolidateHttpClientResponseBytes`：
  /// 这一层要对「没有 Flutter 的环境」保持可用（命令行对端、跨进程联调）。
  static Future<Uint8List> _readAll(HttpClientResponse res) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
      if (builder.length > _maxBody) {
        throw const LanSyncException('对端发来的内容太大');
      }
    }
    return builder.takeBytes();
  }
}

class LanSyncException implements Exception {
  const LanSyncException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 失败时给一句能动手的话，而不是一个状态码加一个冒号。
///
/// 502 / 503 / 504 几乎不是 passbook 自己回的——它的服务端只会回
/// 404 / 403 / 405 / 500。这些码来自中间的代理或网关：这台设备开着
/// TUN 或全局模式的代理时，连内网地址也会被接管，于是「对方不让拉」
/// 后面什么理由都没有（实测就是这样：空的口号什么都说明不了）。
/// 把这一层说破，人才知道该去关代理，还是该给局域网加一条直连规则。
String explainSyncFailure(int status, String body) {
  final detail = body.trim();
  if (detail.isNotEmpty) return '：$detail';
  return switch (status) {
    502 || 503 || 504 =>
      '：对方没有说明原因。这个码通常来自中间的代理或网关——'
          '如果这台设备上开着代理（尤其是 TUN 或全局模式），把它关掉，'
          '或者让局域网地址走直连，再试一次。',
    404 => '：这个端口上不是 passbook 的同步服务，确认地址与端口抄对了。',
    403 => '：配对码不对，用对端屏幕上此刻显示的那个。',
    _ => '：对方没有说明原因。',
  };
}

/// 局域网自动发现：一台开着同步，另一台点一下就看到它——不用抄地址和端口。
///
/// **只暴露「这个地址上有一台 passbook 在等连接」，不带配对码。**
/// 配对码仍是唯一的内容授权；发现只解决「往哪连」这一半。
///
/// 用 UDP 广播而不是多播：家用路由器几乎都转发受限广播，多播则看配置。
/// 探测发三次、每次隔 120 毫秒，丢一两个包也不至于一次都收不到。
class LanDiscovery {
  /// 发现用的端口，与同步用的 HTTP 端口无关（那个由系统每次随机分配）。
  static const int udpPort = 37600;

  static const String probeMagic = 'PASSBOOK-DISCOVERY/1';
  static const String replyMagic = 'PASSBOOK-HERE/1';

  /// 一次扫描等多久。太短会漏掉反应慢的设备，太长让人以为界面卡死了。
  static const Duration scanWindow = Duration(seconds: 2);

  /// 开始应答探测。返回的 socket 要在停止同步时 close 掉。
  static Future<RawDatagramSocket> announce({
    required int syncPort,
    String? name,
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      udpPort,
      reuseAddress: true,
    );
    var hostName = (name ?? '').trim();
    if (hostName.isEmpty) {
      try {
        hostName = Platform.localHostname;
      } catch (_) {
        hostName = '';
      }
    }
    final payload = jsonEncode({
      'name': _sanitize(hostName),
      'port': syncPort,
    });
    final reply = utf8.encode('$replyMagic $payload');
    final probe = utf8.encode(probeMagic);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      // 只认自己那一句：局域网里别的程序也会打这个端口。
      if (!_sameBytes(datagram.data, probe)) return;
      try {
        socket.send(reply, datagram.address, datagram.port);
      } catch (_) {
        // 对方已经走了，回不回去都不影响它。
      }
    });
    return socket;
  }

  /// 广播一次探测，收回所有回应。
  static Future<List<DiscoveredPeer>> scan({
    Duration window = scanWindow,
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final found = <String, DiscoveredPeer>{};
    try {
      socket.broadcastEnabled = true;
    } catch (_) {
      // 系统不许广播时仍然往下走：收不到就如实报「没找到」。
    }
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final peer = DiscoveredPeer.tryParse(
        datagram.address.address,
        datagram.data,
      );
      if (peer != null) found[peer.key] = peer;
    });
    final probe = utf8.encode(probeMagic);
    for (var i = 0; i < 3; i++) {
      try {
        socket.send(probe, InternetAddress('255.255.255.255'), udpPort);
      } catch (_) {
        // 广播被拒（有些网络禁用），继续等已经发出去那一发的回应。
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    await Future<void>.delayed(window);
    await sub.cancel();
    socket.close();
    return found.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 主机名是从网线上来的，按不可信内容处理：控制字符剔掉、长度封顶。
  static String _sanitize(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
  }
}

/// 扫描到的一台设备。
class DiscoveredPeer {
  const DiscoveredPeer({
    required this.host,
    required this.name,
    required this.port,
  });

  /// 回应包的源地址。这个由系统填，对端谎报不了。
  final String host;

  /// 对方自报的机器名，只用来显示，已剔除控制字符。
  final String name;

  /// 对方同步页正在监听的端口。
  final int port;

  /// 去重键：同一台机器可能被多块网卡各回一次。
  String get key => '$host:$port';

  static DiscoveredPeer? tryParse(String host, Uint8List data) {
    final String text;
    try {
      text = utf8.decode(data, allowMalformed: true).trim();
    } catch (_) {
      return null;
    }
    if (!text.startsWith(LanDiscovery.replyMagic)) return null;
    final rest = text.substring(LanDiscovery.replyMagic.length).trim();
    try {
      final map = jsonDecode(rest);
      if (map is! Map) return null;
      final port = map['port'];
      if (port is! int || port <= 0 || port > 65535) return null;
      final rawName = map['name'];
      final name = rawName is String ? LanDiscovery._sanitize(rawName) : '';
      return DiscoveredPeer(
        host: host,
        name: name.isEmpty ? host : name,
        port: port,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Socket 层的失败翻译成能动手的话。
///
/// 界面原来直接把 `SocketException: No route to host ... errno = 113` 摊出来，
/// 那串东西对使用者零信息量——它既不说「哪一步错了」，也不说「该改什么」。
///
/// errno 在 Windows 与 Linux/Android 上不是一套编码（同样是「连不上」，
/// 一边是 10061，另一边是 111），所以两套码 + 英文关键词一起判；
/// 都匹配不到时至少把原始 errno 留着，别把它吞掉。
String explainSocketFailure(
  SocketException e, {
  required String host,
  required int port,
}) {
  final os = e.osError;
  final code = os?.errorCode ?? 0;
  final message = (os?.message ?? e.message).toLowerCase();
  final refused = code == 10061 || code == 111 ||
      message.contains('refused') ||
      message.contains('拒绝');
  final unreachable = code == 10065 || code == 10051 || code == 113 ||
      code == 101 ||
      message.contains('route') ||
      message.contains('unreachable') ||
      message.contains('不可达');
  final timedOut = code == 10060 || code == 110 ||
      message.contains('timed out') ||
      message.contains('timeout');
  if (refused) {
    return '连不上 $host:$port —— 这个端口上没有服务在听。'
        '最可能是对方不在同步页上（那页开着才算在等连接），'
        '或者端口填成了上一次的。';
  }
  if (unreachable) {
    return '连不上 $host:$port —— 这个地址在你的网络里到不了。'
        '常见三种：两台设备不在同一个局域网、这台设备开着 VPN'
        '（VPN 会把局域网流量也带走）、或者填的是对方一块不在线的网卡地址。';
  }
  if (timedOut) {
    return '连 $host:$port 超时 —— 包发出去了没有回应，通常是防火墙把它拦下了。'
        '在对方那台机器上让 passbook 通过防火墙的专用网络。';
  }
  final raw = os?.message ?? e.message;
  return '连不上 $host:$port（$raw${code == 0 ? '' : '，错误码 $code'}）';
}

/// 一次配对邀请：对端拿到这三样就能连。
///
/// 二维码里装的就是它。加这层的理由很实在：手抄三样东西**必然抄错过**
/// （实测抄成了 WSL 的虚拟网卡地址，另一头只回一个 502，人根本不知道
/// 错在哪一步）。扫一次就没有中间那双手。
class SyncOffer {
  const SyncOffer({required this.host, required this.port, required this.code});

  final String host;
  final int port;

  /// 六位一次性配对码。
  final String code;

  static const _scheme = 'passbook';
  static const _prefixHost = 'sync';

  /// `passbook://sync?host=192.168.1.7&port=42545&code=729980`
  ///
  /// 用自定义 scheme 而不是裸 JSON 或裸网址：扫出来一眼能认出这是哪来的，
  /// 别的扫码器也不会把它当成网页打开。
  String toUri() => Uri(
    scheme: _scheme,
    host: _prefixHost,
    queryParameters: {'host': host, 'port': '$port', 'code': code},
  ).toString();

  /// 解析扫到的内容。返回 null = 这不是本应用的码（或内容不完整）。
  ///
  /// 两种写法都收：一是本应用给的 URI；二是「地址 端口 码」三段纯文本
  /// ——别的扫码工具常把人能看到的内容原样显示出来，人转述时就是那样。
  /// 宽容一点没有代价：格式严格只会在真实的扫码场景里制造失败。
  static SyncOffer? tryParse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final uri = Uri.tryParse(text);
    if (uri != null && uri.scheme == _scheme && uri.host == _prefixHost) {
      final host = uri.queryParameters['host'] ?? '';
      final port = int.tryParse(uri.queryParameters['port'] ?? '');
      final code = uri.queryParameters['code'] ?? '';
      if (_valid(host, port, code)) {
        return SyncOffer(host: host, port: port!, code: code);
      }
      return null;
    }

    final parts = text
        .split(RegExp(r'[\s,;·]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length == 3) {
      final port = int.tryParse(parts[1]);
      if (_valid(parts[0], port, parts[2])) {
        return SyncOffer(host: parts[0], port: port!, code: parts[2]);
      }
    }
    return null;
  }

  static bool _valid(String host, int? port, String code) {
    if (host.isEmpty) return false;
    if (port == null || port <= 0 || port > 65535) return false;
    // 端口与码的位数都要对得上：六位是这个应用的约定，别的长度一定是
    // 扫到了另一个东西的码，宁可拒绝，也不能拿着错的码去敲对端的门。
    if (code.length != 6 || int.tryParse(code) == null) return false;
    return true;
  }
}
