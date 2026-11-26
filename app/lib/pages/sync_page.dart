import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  String? _myCode;
  int? _myPort;
  bool _busy = false;
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
                        const SizedBox(height: 12),
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
                                '$_myPort 端口 · $ip',
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
