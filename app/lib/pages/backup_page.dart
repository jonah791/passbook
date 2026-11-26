import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/backup.dart';
import '../core/vault_controller.dart';

/// 备份与恢复。
///
/// 界面刻意把「合并」和「替换」分成两个动作、两段说明：它们后果完全不同，
/// 合成一个「恢复」按钮，用户迟早会在该合并的时候按了替换。
class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.vault});

  final VaultController vault;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

typedef _BackupItem = ({File file, int bytes});

class _BackupPageState extends State<BackupPage> {
  late final BackupService _svc;
  List<_BackupItem> _history = const [];
  bool _busy = false;
  bool _loading = true;
  String? _error;
  String? _note;

  @override
  void initState() {
    super.initState();
    _svc = BackupService(widget.vault);
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final files = await _svc.listHistory();
      final items = <_BackupItem>[];
      for (final f in files) {
        int bytes = 0;
        try {
          bytes = await f.length();
        } on FileSystemException {
          continue; // 刚被删掉的，直接跳过
        }
        items.add((file: f, bytes: bytes));
      }
      if (!mounted) return;
      setState(() {
        _history = items;
        _loading = false;
        _error = null;
      });
    } on FileSystemException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读不到备份目录：${e.message}';
      });
    }
  }

  void _say(String text) {
    if (!mounted) return;
    setState(() {
      _note = text;
      _error = null;
    });
  }

  void _fail(String text) {
    if (!mounted) return;
    setState(() {
      _error = text;
      _note = null;
    });
  }

  // ── 导出 ──────────────────────────────────────────────────────────────────

  Future<void> _export() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    final suggested = BackupService.suggestedName(DateTime.now());
    try {
      String? chosen;
      try {
        // `bytes` 在安卓/iOS 上是必需品：那两个平台由插件自己把内容写进用户选的
        // 文档位置，然后回一个路径。桌面端忽略它，只回路径，要我们自己写。
        // 不传 bytes 的后果实测过：安卓上根本弹不出保存界面，只能退到私有目录，
        // 而私有目录用户是拿不到的——备份等于没做。
        chosen = await FilePicker.platform.saveFile(
          dialogTitle: '把密码本备份存到哪里',
          fileName: suggested,
          type: FileType.custom,
          allowedExtensions: const ['kdbx'],
          bytes: await widget.vault.exportBytes(),
        );
      } on Object {
        chosen = null; // 这个平台没有保存对话框，走应用自己的备份目录
      }

      if (chosen != null && chosen.isNotEmpty) {
        try {
          final target = File(chosen);
          // 安卓由插件写好了；桌面只拿到路径，得我们自己写。
          final already = await target.exists() && await target.length() > 0;
          final n = already
              ? await target.length()
              : await _svc.exportTo(target);
          _say('已导出 ${BackupService.humanSize(n)} → $chosen');
          setState(() => _busy = false);
          await _refresh();
          return;
        } on FileSystemException {
          // 用户选的位置写不进去（某些文档提供者是只读的），退回自己的目录
        }
      }

      final f = await _svc.exportHistory();
      final n = await f.length();
      _say('已导出 ${BackupService.humanSize(n)} → ${f.path}');
      setState(() => _busy = false);
      await _refresh();
    } on Object catch (e) {
      setState(() => _busy = false);
      _fail('导出失败：$e');
    }
  }

  // ── 恢复 ──────────────────────────────────────────────────────────────────

  /// 从任意位置挑一个 `.kdbx` 文件。
  ///
  /// 安卓上不用 `FileType.custom`：它的扩展名过滤要靠 MIME 类型映射，而 `.kdbx`
  /// 没有公认的 MIME，结果是一个文件都选不出来（实测点了没反应）。那边放开类型、
  /// 选完自己认扩展名；桌面端的过滤是原生的，照用。
  Future<File?> _pickFile() async {
    final android = Platform.isAndroid;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选一份密码本备份',
      type: android ? FileType.any : FileType.custom,
      allowedExtensions: android ? null : const ['kdbx'],
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) return null;
    if (!path.toLowerCase().endsWith('.kdbx')) {
      _fail('这个文件不是密码本备份（.kdbx）');
      return null;
    }
    return File(path);
  }

  Future<void> _mergeFrom(File source) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      final r = await _svc.mergeFrom(source);
      _say('已合并：${r.summary}');
    } on Object catch (e) {
      _fail('合并失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _replaceFrom(File source) async {
    if (_busy) return;
    final stamp = BackupService.humanTime(source);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('用这份备份替换整个库？'),
        content: Text(
          '库会回到「$stamp」那一刻的样子。\n\n'
          '备份之后新增或改过的条目会消失——这两件事合并做不到，只能替换。\n\n'
          '替换前会先把现在的库另存一份，所以真后悔了还找得回来。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('算了'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('替换'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      final safety = await _svc.replaceFrom(source);
      _say('已替换。替换前的现状另存在：${safety.path}');
      await _refresh();
    } on Object catch (e) {
      _fail('替换失败（库没有被改动）：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删掉这份备份？'),
        content: Text('${BackupService.humanTime(f)} 那份会被永久删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('算了'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _svc.deleteHistory(f);
      _say('已删除一份备份。');
      await _refresh();
    } on Object catch (e) {
      _fail('删除失败：$e');
    }
  }

  // ── 界面 ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final soft = theme.colorScheme.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 44),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '备份文件就是密码本的密文，用你的主密码才打得开——'
              '放在哪都不用担心，但密码别丢。',
              style: TextStyle(fontSize: 13, height: 1.7, color: soft),
            ),
            const SizedBox(height: 26),

            _section(theme, '导出'),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: _busy ? null : _export,
              child: Text(_busy ? '处理中…' : '导出一份备份'),
            ),
            const SizedBox(height: 10),
            Text(
              '会先问你要存到哪；没法选就放进应用自己的备份目录。',
              style: TextStyle(fontSize: 12.5, height: 1.6, color: soft),
            ),
            const SizedBox(height: 30),

            _section(theme, '历史备份'),
            const SizedBox(height: 12),
            if (_loading)
              Text('读取中…', style: TextStyle(fontSize: 13, color: soft))
            else if (_history.isEmpty)
              Text(
                '还没有备份。第一次导出之后，这里会出现每一份的时间与大小。',
                style: TextStyle(fontSize: 13, height: 1.7, color: soft),
              )
            else
              for (final item in _history) _historyRow(theme, item),
            const SizedBox(height: 30),

            _section(theme, '从文件恢复'),
            const SizedBox(height: 12),
            // 一行对比，不再各写一段原理。真正的差异在点下去之后的确认框里
            // 还会说一次——那里才是人需要它的时候。
            Text(
              '「合并」是补进来（误删的救不回来），「替换」是回到那一刻。',
              style: TextStyle(fontSize: 13, height: 1.7, color: soft),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final f = await _pickFile();
                          if (f != null) await _mergeFrom(f);
                        },
                  child: const Text('选文件并合并 →'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final f = await _pickFile();
                          if (f != null) await _replaceFrom(f);
                        },
                  child: const Text('选文件并替换…'),
                ),
              ],
            ),

            if (_error != null) ...[
              const SizedBox(height: 18),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (_note != null) ...[
              const SizedBox(height: 18),
              SelectableText(
                _note!,
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _historyRow(ThemeData theme, _BackupItem item) {
    final soft = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(
            BackupService.humanTime(item.file),
            style: const TextStyle(fontSize: 13.5, fontFamily: 'Consolas'),
          ),
          const SizedBox(width: 14),
          Text(
            BackupService.humanSize(item.bytes),
            style: TextStyle(fontSize: 12.5, color: soft),
          ),
          const Spacer(),
          TextButton(
            onPressed: _busy ? null : () => _mergeFrom(item.file),
            child: const Text('合并'),
          ),
          TextButton(
            onPressed: _busy ? null : () => _replaceFrom(item.file),
            child: const Text('替换'),
          ),
          TextButton(
            onPressed: _busy ? null : () => _delete(item.file),
            child: const Text('删掉'),
          ),
        ],
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
