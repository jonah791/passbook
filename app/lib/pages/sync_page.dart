import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/sync_lan.dart';
import '../core/vault_controller.dart';
import '../theme/app_theme.dart';

/// 局域网同步：一边显示自己的地址与配对码等对方来连，一边可以填对端地址去连。
///
/// 页面一关端点就关——不做常驻监听。密码本没有「后台待命」的理由。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.vault});

  final VaultController vault;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  late final LanSync _sync;
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _code = TextEditingController();

  List<String> _ips = const [];
  List<DiscoveredPeer> _peers = const [];
  String? _myCode;
  int? _myPort;
  bool _busy = false;
  bool _scanning = false;
  String? _error;
  MergeResult? _result;
  String? _resultFrom;

  @override
  void initState() {
    super.initState();
    _sync = LanSync(widget.vault)
      ..onMerged = (result) {
        if (!mounted) return;
        setState(() {
          _result = result;
          _resultFrom = '对端';
          _myCode = _sync.code; // 码已一次性作废并换新
          _error = null;
        });
      };
    unawaited(_boot());
  }

  @override
  void dispose() {
    unawaited(_sync.stop());
    _host.dispose();
    _port.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final ips = await LanSync.localIPv4();
    final code = await _sync.start();
    if (!mounted) return;
    setState(() {
      _ips = ips;
      _myCode = code;
      _myPort = _sync.port;
    });
  }

  Future<void> _connect() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final code = _code.text.trim();
    if (host.isEmpty || port == null || code.isEmpty) {
      setState(() => _error = '把对端的地址、端口和配对码都填上');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final result = await _sync.pullFrom(host: host, port: port, code: code);
      if (!mounted) return;
      setState(() {
        _result = result;
        _resultFrom = '你这边';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyCode() async {
    final code = _myCode;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('配对码已复制'), duration: Duration(seconds: 2)),
    );
  }

  /// 在局域网里找正在等连接的 passbook，省掉抄地址和端口。
  ///
  /// 找到的只有地址和端口——**配对码不在里面**，那六位数仍要人看对方屏幕
  /// 或扫码带过来。发现解决的是「往哪连」，不是「凭什么让你连」。
  Future<void> _discover() async {
    setState(() {
      _scanning = true;
      _peers = const [];
      _error = null;
    });
    final peers = await LanDiscovery.scan();
    if (!mounted) return;
    // 自己这台也会回一个包——剔掉，否则列表第一条就是「连我自己」。
    final others = peers.where((p) => !_ips.contains(p.host)).toList();
    setState(() {
      _scanning = false;
      _peers = others;
      if (others.isEmpty) {
        _error = '没找到别的设备。确认另一台停在同步页上（那页开着才算在等连接），'
            '并且两台连的是同一个局域网。';
      }
    });
  }

  void _usePeer(DiscoveredPeer peer) {
    setState(() {
      _host.text = peer.host;
      _port.text = '${peer.port}';
      _peers = const [];
      _error = null;
    });
  }

  Widget _peerRow(ThemeData theme, Color soft, DiscoveredPeer peer) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: (_busy || _scanning) ? null : () => _usePeer(peer),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.name,
                      style: const TextStyle(fontSize: 14.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${peer.host} · 端口 ${peer.port}',
                      style: TextStyle(
                        fontSize: 12,
                        color: soft,
                        fontFamily: 'Consolas',
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.north_east, size: 15, color: soft),
            ],
          ),
        ),
      ),
    );
  }

  /// 二维码里装什么。
  ///
  /// 多网卡时只用第一个：`LanSync.localIPv4` 已经把虚拟网卡剔掉了，排第一的
  /// 是真实网卡。其余地址仍列在下面，扫码不通时人可以手填另一个。
  SyncOffer? get _offer {
    final code = _myCode;
    final port = _myPort;
    if (code == null || port == null || _ips.isEmpty) return null;
    return SyncOffer(host: _ips.first, port: port, code: code);
  }

  /// 只有带摄像头的端能扫。桌面端没有摄像头扫码能力（插件也不支持 Windows），
  /// 那边就只显示码、不出现这个按钮——出现一个点了必然失败的按钮更糟。
  bool get _canScan => Platform.isAndroid;

  Future<void> _scan() async {
    final offer = await Navigator.of(
      context,
    ).push<SyncOffer>(MaterialPageRoute(builder: (_) => const _ScanPage()));
    if (!mounted || offer == null) return;
    setState(() {
      _host.text = offer.host;
      _port.text = '${offer.port}';
      _code.text = offer.code;
      _error = null;
    });
    // 扫完直接连：扫码的目的就是省掉「再点一次」。连接失败会照常显示原因。
    await _connect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final soft = theme.colorScheme.onSurfaceVariant;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Palette.listWidth),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 16, 4),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '返回（Esc）',
                          icon: const Icon(Icons.arrow_back_ios_new, size: 15),
                          color: soft,
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                        const SizedBox(width: 8),
                        Text('局域网同步', style: theme.textTheme.titleMedium),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 64),
                      children: [
                        Text(
                          '两台设备连同一个 WiFi，一台开着这个页面，另一台填它的地址。'
                          '内容全程是加密的库，谁拿到也解不开。',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.6,
                            color: soft,
                          ),
                        ),
                        const SizedBox(height: 28),
                        _section(theme, '这台设备'),
                        const SizedBox(height: 14),
                        _qrBlock(theme),
                        const SizedBox(height: 14),
                        if (_ips.isEmpty)
                          Text(
                            '没找到局域网地址——先确认连上了 WiFi。',
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.error,
                            ),
                          )
                        else
                          for (final ip in _ips)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: SelectableText(
                                // 地址在前、端口在后：与下面「连另一台」的两个
                                // 输入框同序。反过来写，人抄的时候容易抄反。
                                '$ip   端口 $_myPort',
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  fontFamily: 'Consolas',
                                  height: 1.5,
                                ),
                              ),
                            ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Text(
                              _myCode ?? '……',
                              style: const TextStyle(
                                fontSize: 26,
                                letterSpacing: 6,
                                fontFamily: 'Consolas',
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(width: 14),
                            TextButton(
                              onPressed: _copyCode,
                              child: const Text('复制配对码'),
                            ),
                          ],
                        ),
                        Text(
                          '配对码只对下一次连入有效，用过就换。',
                          style: TextStyle(fontSize: 12, color: soft),
                        ),
                        const SizedBox(height: 34),
                        _section(theme, '连另一台'),
                        const SizedBox(height: 14),
                        // 扫码的路只在有摄像头的端出现。桌面端没有这条能力
                        // （插件也不支持 Windows），那边只显示码、让人用手填。
                        if (_canScan) ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => unawaited(_scan()),
                              icon: const Icon(Icons.qr_code_scanner, size: 16),
                              label: const Text('扫对方的二维码'),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '扫一次，就不用抄下面这三样。',
                            style: TextStyle(fontSize: 12, color: soft),
                          ),
                          const SizedBox(height: 20),
                        ],
                        // 两端都有的一条路：广播一次，让对面自己冒出来。
                        // 桌面端没有摄像头，这条是它唯一不用手抄的方式。
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: (_busy || _scanning)
                                ? null
                                : () => unawaited(_discover()),
                            icon: _scanning
                                ? const SizedBox(
                                    width: 13,
                                    height: 13,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.6,
                                    ),
                                  )
                                : const Icon(Icons.wifi_find, size: 16),
                            label: Text(_scanning ? '正在找…' : '在局域网里找'),
                          ),
                        ),
                        if (_peers.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          ..._peers.map((p) => _peerRow(theme, soft, p)),
                          const SizedBox(height: 4),
                          Text(
                            '点一台就填好地址和端口；六位配对码还得看你另一台屏幕上那个。',
                            style: TextStyle(fontSize: 12, color: soft),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextField(
                                controller: _host,
                                decoration: const InputDecoration(
                                  hintText: '地址，如 192.168.1.7',
                                ),
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  fontFamily: 'Consolas',
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: _port,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  hintText: '端口',
                                ),
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  fontFamily: 'Consolas',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _code,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            hintText: '对方屏幕上的六位配对码',
                          ),
                          style: const TextStyle(
                            fontSize: 14.5,
                            letterSpacing: 2,
                            fontFamily: 'Consolas',
                          ),
                        ),
                        const SizedBox(height: 22),
                        Row(
                          children: [
                            const Spacer(),
                            TextButton(
                              onPressed: _busy ? null : _connect,
                              child: Text(_busy ? '连接中…' : '连接并合并 →'),
                            ),
                          ],
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            _error!,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.6,
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ],
                        if (_result != null) ...[
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              Text(
                                '$_resultFrom：',
                                style: TextStyle(fontSize: 13, color: soft),
                              ),
                              Text(
                                _result!.summary,
                                style: const TextStyle(fontSize: 13.5),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 二维码。黑白、白底——这不是审美选择，是能不能扫出来的问题：
  /// 纸色底配淡墨点，摄像头读不出那个对比度。全站唯一一处纯白是有理由的。
  Widget _qrBlock(ThemeData theme) {
    final offer = _offer;
    if (offer == null) {
      return Text(
        '配对码准备中…',
        style: TextStyle(
          fontSize: 13,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Center(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(Palette.radius),
          border: Border.all(color: theme.colorScheme.outline, width: 0.5),
        ),
        child: QrImageView(
          data: offer.toUri(),
          version: QrVersions.auto,
          size: 190,
          gapless: true,
          backgroundColor: Colors.white,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Colors.black,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Colors.black,
          ),
        ),
      ),
    );
  }

  Widget _section(ThemeData theme, String title) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 0.8,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Divider(height: 0.5, color: theme.colorScheme.outline)),
      ],
    );
  }
}

/// 扫码页。只认本应用的码：别的二维码扫进来会被 [SyncOffer.tryParse] 挡掉，
/// 页面继续取景，不弹错——举着的可能是别人的名片码，没必要为此打断。
class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  final _controller = MobileScannerController(
    // 同一个码在画面里停两秒会连回调好几次，去重交给插件。
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  /// 认到之后立刻置位：pop 要一帧才生效，这期间可能还有回调进来。
  bool _handled = false;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final offer = SyncOffer.tryParse(raw);
      if (offer == null) continue;
      _handled = true;
      Navigator.of(context).pop(offer);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('扫对方的二维码'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // 取景框只是个提示，不加遮罩：遮住画面反而让人对不准。
          IgnorePointer(
            child: Center(
              child: Container(
                width: 230,
                height: 230,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white70, width: 1.5),
                  borderRadius: BorderRadius.circular(Palette.radius),
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 44,
            child: Text(
              '把对方屏幕上的二维码放进框里，扫到就会自动连。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
