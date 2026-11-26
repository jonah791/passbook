import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kpasslib/kpasslib.dart';

import '../core/vault_controller.dart';

/// 便签式界面：打开即列表，点加号就能记，自动保存。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.vault});

  final VaultController vault;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _checking = true;
  String? _lastPath;
  bool _unlocked = false;
  bool _creating = false;
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _search = TextEditingController();
  String _query = '';
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.vault.addListener(_onVault);
    _boot();
  }

  @override
  void dispose() {
    widget.vault.removeListener(_onVault);
    _password.dispose();
    _confirm.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onVault() {
    if (mounted) setState(() {});
  }

  Future<void> _boot() async {
    final path = await widget.vault.readLastPath();
    if (!mounted) return;
    setState(() {
      _lastPath = path;
      _checking = false;
    });
  }

  Future<void> _unlock() async {
    final path = _lastPath;
    if (path == null) return;
    if (_password.text.isEmpty) {
      setState(() => _error = '请输入主密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.vault.open(path, _password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _unlocked = ok;
      _error = ok ? null : widget.vault.lastError;
    });
    if (ok) _password.clear();
  }

  Future<void> _create() async {
    if (_password.text.isEmpty) {
      setState(() => _error = '主密码不能为空');
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = '两次输入不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.vault.createDefault(_password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _unlocked = ok;
      _error = ok ? null : widget.vault.lastError;
    });
    if (ok) {
      _password.clear();
      _confirm.clear();
    }
  }

  void _lock() {
    widget.vault.close();
    setState(() {
      _unlocked = false;
      _creating = false;
    });
  }

  Future<void> _newNote() async {
    final entry = widget.vault.addEntry();
    await _openEditor(entry);
  }

  Future<void> _openEditor(KdbxEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(vault: widget.vault, entry: entry),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _copy(String text, String label) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制$label（30 秒后自动清空）')),
    );
    Timer(const Duration(seconds: 30), () async {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == text) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_unlocked) {
      return _lockedScaffold();
    }
    return _listScaffold();
  }

  Widget _lockedScaffold() {
    final hasVault = _lastPath != null && !_creating;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.lock_outline, size: 56),
                const SizedBox(height: 12),
                Text(
                  hasVault ? '解锁密码本' : '创建密码本',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  hasVault ? '输入主密码继续' : '设一个主密码，之后每次打开都用它',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofocus: true,
                  onSubmitted: (_) =>
                      hasVault ? _unlock() : _create(),
                  decoration: const InputDecoration(
                    labelText: '主密码',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (!hasVault) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirm,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '再输一次',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : (hasVault ? _unlock : _create),
                  child: Text(hasVault ? '解锁' : '创建'),
                ),
                if (hasVault) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _creating = true;
                              _error = null;
                            }),
                    child: const Text('用别的库？'),
                  ),
                ],
                if (!hasVault && _lastPath != null) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => setState(() => _creating = false),
                    child: const Text('返回解锁'),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _listScaffold() {
    final entries = widget.vault.allEntries.where((entry) {
      if (_query.trim().isEmpty) return true;
      final q = _query.trim().toLowerCase();
      return widget.vault
              .fieldOf(entry, 'Title')
              .toLowerCase()
              .contains(q) ||
          widget.vault.fieldOf(entry, 'Notes').toLowerCase().contains(q) ||
          widget.vault.fieldOf(entry, 'UserName').toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: TextField(
          controller: _search,
          onChanged: (value) => setState(() => _query = value),
          decoration: const InputDecoration(
            hintText: '搜索',
            border: InputBorder.none,
            prefixIcon: Icon(Icons.search, size: 20),
            isDense: true,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '锁定',
            onPressed: _lock,
            icon: const Icon(Icons.lock_outline, size: 20),
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(child: Text('还没有条目，点右下角 + 记一条'))
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = entries[index];
                final title = widget.vault.fieldOf(entry, 'Title');
                final preview = widget.vault.previewOf(entry);
                final hasPassword = widget.vault.hasPassword(entry);
                return ListTile(
                  title: Text(
                    title.isEmpty ? '无标题' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: preview.isEmpty
                      ? null
                      : Text(
                          preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: hasPassword
                      ? IconButton(
                          tooltip: '复制密码',
                          icon: const Icon(Icons.key_outlined, size: 20),
                          onPressed: () => _copy(
                            widget.vault.fieldOf(entry, 'Password'),
                            '密码',
                          ),
                        )
                      : null,
                  onTap: () => _openEditor(entry),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _newNote,
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// 全屏编辑：标题 + 正文，改动 800ms 后自动保存。
class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({super.key, required this.vault, required this.entry});

  final VaultController vault;
  final KdbxEntry entry;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _url;
  Timer? _saveTimer;
  bool _showSecret = false;
  bool _reveal = false;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _title = TextEditingController(text: widget.vault.fieldOf(e, 'Title'));
    _body = TextEditingController(text: widget.vault.fieldOf(e, 'Notes'));
    _username = TextEditingController(text: widget.vault.fieldOf(e, 'UserName'));
    _password = TextEditingController(text: widget.vault.fieldOf(e, 'Password'));
    _url = TextEditingController(text: widget.vault.fieldOf(e, 'URL'));
    _showSecret = _password.text.isNotEmpty;
    _title.addListener(_scheduleSave);
    _body.addListener(_scheduleSave);
    _username.addListener(_scheduleSave);
    _password.addListener(_scheduleSave);
    _url.addListener(_scheduleSave);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _title.dispose();
    _body.dispose();
    _username.dispose();
    _password.dispose();
    _url.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _flush);
  }

  Future<void> _flush() async {
    final e = widget.entry;
    widget.vault.updateField(e, 'Title', _title.text);
    widget.vault.updateField(e, 'Notes', _body.text);
    widget.vault.updateField(e, 'UserName', _username.text);
    widget.vault.updateField(e, 'Password', _password.text);
    widget.vault.updateField(e, 'URL', _url.text);
    await widget.vault.save();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _saveTimer?.cancel();
    widget.vault.deleteEntry(widget.entry);
    await widget.vault.save();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: '删除',
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          TextField(
            controller: _title,
            autofocus: _title.text.isEmpty,
            style: Theme.of(context).textTheme.headlineSmall,
            decoration: const InputDecoration(
              hintText: '标题',
              border: InputBorder.none,
            ),
          ),
          TextField(
            controller: _body,
            maxLines: null,
            minLines: 8,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              hintText: '记点什么…',
              border: InputBorder.none,
            ),
          ),
          const Divider(),
          if (!_showSecret)
            TextButton.icon(
              onPressed: () => setState(() => _showSecret = true),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加账号密码'),
            )
          else ...[
            TextField(
              controller: _username,
              decoration: const InputDecoration(labelText: '用户名 / 账号'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _password,
              obscureText: !_reveal,
              decoration: InputDecoration(
                labelText: '密码',
                suffixIcon: IconButton(
                  icon: Icon(
                    _reveal ? Icons.visibility_off : Icons.visibility,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _reveal = !_reveal),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _url,
              decoration: const InputDecoration(labelText: '网址'),
            ),
          ],
        ],
      ),
    );
  }
}
