import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../main.dart' show vault;
import 'vault_page.dart';

class UnlockPage extends StatefulWidget {
  const UnlockPage({super.key});

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  bool _busy = false;

  Future<void> _create() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '新建密码库',
      fileName: 'passbook.kdbx',
      initialDirectory: dir.path,
      type: FileType.any,
    );
    if (path == null || !mounted) return;
    final password = await _askPassword(title: '设置主密码', confirm: true);
    if (password == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await vault.createNew(path, password);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const VaultPage()),
      );
    } catch (e) {
      _showError('新建失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '打开密码库',
      type: FileType.any,
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    final password = await _askPassword(title: '输入主密码');
    if (password == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await vault.open(path, password);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const VaultPage()),
      );
    } catch (e) {
      _showError('打开失败：主密码不对，或文件不是 KDBX 库。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askPassword({
    required String title,
    bool confirm = false,
  }) async {
    final first = TextEditingController();
    final second = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: first,
                    obscureText: true,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: '主密码'),
                  ),
                  if (confirm) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: second,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '再输一次'),
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final value = first.text;
                    if (value.isEmpty) {
                      setState(() => error = '密码不能为空');
                      return;
                    }
                    if (confirm && value != second.text) {
                      setState(() => error = '两次输入不一致');
                      return;
                    }
                    Navigator.of(ctx).pop(value);
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.lock_outline, size: 64),
                const SizedBox(height: 16),
                Text(
                  'Passbook',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '本地优先 · 零外联 · 标准 KDBX',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 40),
                FilledButton.icon(
                  onPressed: _busy ? null : _create,
                  icon: const Icon(Icons.add),
                  label: const Text('新建密码库'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _open,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('打开已有库'),
                ),
                const SizedBox(height: 24),
                if (_busy) const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
