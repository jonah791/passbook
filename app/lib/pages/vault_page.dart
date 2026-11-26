import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kpasslib/kpasslib.dart';

import '../main.dart' show vault;
import 'editor_page.dart';
import 'unlock_page.dart';

class VaultPage extends StatefulWidget {
  const VaultPage({super.key});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  KdbxGroup? _selectedGroup;
  KdbxEntry? _selectedEntry;
  String _query = '';
  bool _revealPassword = false;

  @override
  void initState() {
    super.initState();
    vault.addListener(_onVaultChanged);
  }

  @override
  void dispose() {
    vault.removeListener(_onVaultChanged);
    super.dispose();
  }

  void _onVaultChanged() {
    if (!mounted) return;
    setState(() {});
  }

  List<KdbxEntry> get _visibleEntries {
    final base = _selectedGroup?.allEntries ?? vault.allEntries;
    if (_query.trim().isEmpty) return base;
    final q = _query.trim().toLowerCase();
    return base.where((entry) {
      final title = vault.fieldOf(entry, 'Title').toLowerCase();
      final user = vault.fieldOf(entry, 'UserName').toLowerCase();
      return title.contains(q) || user.contains(q);
    }).toList();
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

  Future<void> _save() async {
    await vault.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存')),
    );
  }

  void _lock() {
    vault.close();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const UnlockPage()),
      (route) => false,
    );
  }

  void _addEntry() {
    final group = _selectedGroup ?? vault.rootGroup;
    final entry = vault.addEntry(group);
    setState(() {
      _selectedEntry = entry;
    });
    _openEditor(entry);
  }

  Future<void> _addGroup() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '分组名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    vault.addGroup(_selectedGroup ?? vault.rootGroup, name);
    setState(() {});
  }

  void _openEditor(KdbxEntry entry) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EditorPage(entry: entry)),
    );
  }

  void _deleteSelected() {
    final entry = _selectedEntry;
    if (entry == null) return;
    vault.deleteEntry(entry);
    setState(() => _selectedEntry = null);
  }

  String _vaultName() {
    final path = vault.filePath;
    if (path == null || path.isEmpty) return 'Passbook';
    final parts = path.split(RegExp(r'[\\/]'));
    final name = parts.isEmpty ? '' : parts.last;
    return name.isEmpty ? 'Passbook' : name;
  }

  @override
  Widget build(BuildContext context) {
    final groups = vault.rootGroup.groups;
    final entries = _visibleEntries;
    final selected = _selectedEntry;

    return Scaffold(
      appBar: AppBar(
        title: Text(_vaultName()),
        actions: [
          IconButton(
            tooltip: '保存',
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
          ),
          IconButton(
            tooltip: '锁定',
            onPressed: _lock,
            icon: const Icon(Icons.lock_outline),
          ),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 220,
            child: ListView(
              children: [
                ListTile(
                  selected: _selectedGroup == null,
                  leading: const Icon(Icons.folder_special_outlined),
                  title: const Text('全部条目'),
                  onTap: () => setState(() => _selectedGroup = null),
                ),
                const Divider(height: 1),
                for (final group in groups)
                  ListTile(
                    selected: _selectedGroup?.uuid == group.uuid,
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(
                      group.name.isEmpty ? '未命名分组' : group.name,
                    ),
                    subtitle: Text('${group.allEntries.length} 条'),
                    onTap: () => setState(() => _selectedGroup = group),
                  ),
                ListTile(
                  leading: const Icon(Icons.create_new_folder_outlined),
                  title: const Text('新建分组'),
                  onTap: _addGroup,
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          SizedBox(
            width: 320,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索标题或用户名',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(child: Text('没有条目'))
                      : ListView.builder(
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            final selectedRow = selected?.uuid == entry.uuid;
                            return ListTile(
                              selected: selectedRow,
                              leading: const Icon(Icons.key_outlined),
                              title: Text(
                                vault.fieldOf(entry, 'Title').isEmpty
                                    ? '未命名'
                                    : vault.fieldOf(entry, 'Title'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                vault.fieldOf(entry, 'UserName'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => setState(() {
                                _selectedEntry = entry;
                                _revealPassword = false;
                              }),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: FilledButton.icon(
                    onPressed: _addEntry,
                    icon: const Icon(Icons.add),
                    label: const Text('新建条目'),
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: selected == null
                ? const Center(child: Text('选择左侧条目查看详情'))
                : _EntryDetail(
                    entry: selected,
                    revealPassword: _revealPassword,
                    onToggleReveal: () =>
                        setState(() => _revealPassword = !_revealPassword),
                    onCopy: _copy,
                    onEdit: () => _openEditor(selected),
                    onDelete: _deleteSelected,
                  ),
          ),
        ],
      ),
    );
  }
}

class _EntryDetail extends StatelessWidget {
  const _EntryDetail({
    required this.entry,
    required this.revealPassword,
    required this.onToggleReveal,
    required this.onCopy,
    required this.onEdit,
    required this.onDelete,
  });

  final KdbxEntry entry;
  final bool revealPassword;
  final VoidCallback onToggleReveal;
  final Future<void> Function(String text, String label) onCopy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final title = vault.fieldOf(entry, 'Title');
    final username = vault.fieldOf(entry, 'UserName');
    final password = vault.fieldOf(entry, 'Password');
    final url = vault.fieldOf(entry, 'URL');
    final notes = vault.fieldOf(entry, 'Notes');

    Widget row(String label, String value, {Widget? trailing}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 88,
              child: Text(label, style: Theme.of(context).textTheme.labelMedium),
            ),
            Expanded(child: SelectableText(value.isEmpty ? '—' : value)),
            if (trailing != null) trailing,
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.isEmpty ? '未命名' : title,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          row(
            '用户名',
            username,
            trailing: IconButton(
              tooltip: '复制用户名',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => onCopy(username, '用户名'),
            ),
          ),
          row(
            '密码',
            revealPassword ? password : '••••••••',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: revealPassword ? '隐藏' : '显示',
                  icon: Icon(
                    revealPassword ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                  ),
                  onPressed: onToggleReveal,
                ),
                IconButton(
                  tooltip: '复制密码',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => onCopy(password, '密码'),
                ),
              ],
            ),
          ),
          row(
            '网址',
            url,
            trailing: IconButton(
              tooltip: '复制网址',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => onCopy(url, '网址'),
            ),
          ),
          const Divider(),
          row('备注', notes),
          const SizedBox(height: 24),
          Row(
            children: [
              FilledButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('编辑'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
