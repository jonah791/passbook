import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kpasslib/kpasslib.dart';

import '../core/vault_controller.dart';
import '../theme/app_theme.dart';

/// 分组整理：建、改名、删。
///
/// 只做一层分类——便签式的心智里一层就够，多一层要多点一次，小屏上也很难
/// 看清自己在哪。KDBX 结构支持嵌套，别的客户端建的深层分组照旧存在与同步。
///
/// 删除分组时里面条目**不会跟着消失**（见 `VaultController.deleteGroup`）。
/// 这句话必须写在界面上：不写，没人敢按那个按钮。
class GroupPage extends StatefulWidget {
  const GroupPage({super.key, required this.vault});

  final VaultController vault;

  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  @override
  void initState() {
    super.initState();
    widget.vault.addListener(_onVault);
  }

  @override
  void dispose() {
    widget.vault.removeListener(_onVault);
    super.dispose();
  }

  void _onVault() {
    if (mounted) setState(() {});
  }

  Future<void> _create() async {
    final name = await _askName(title: '新建分组', confirm: '建好');
    if (name == null) return;
    widget.vault.createGroup(name);
  }

  Future<void> _rename(KdbxGroup group) async {
    final name = await _askName(
      title: '改个名字',
      confirm: '改好',
      initial: group.name,
    );
    if (name == null) return;
    widget.vault.renameGroup(group, name);
  }

  Future<void> _delete(KdbxGroup group) async {
    final count = group.allEntries.length;
    final hasChildren = group.groups.isNotEmpty;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删掉「${group.name}」？'),
        content: Text(
          count == 0 && !hasChildren
              ? '这个分组是空的，删掉不影响任何条目。'
              : '分组里有 $count 条'
                    '${hasChildren ? '，还有子分组' : ''}。'
                    '删掉分组不会删掉这些东西——它们会回到「未分组」，'
                    '之后还能再拖回别的分组里。',
          style: const TextStyle(fontSize: 13.5, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('算了'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              '删掉',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok ?? false) widget.vault.deleteGroup(group);
  }

  /// 问一个名字。返回 null = 取消或没填。
  Future<String?> _askName({
    required String title,
    required String confirm,
    String? initial,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) =>
          _NameDialog(title: title, confirm: confirm, initial: initial),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final soft = theme.colorScheme.onSurfaceVariant;
    final faint = theme.hintColor;
    final groups = widget.vault.groups;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: Palette.listWidth),
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 12, 4),
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: '返回（Esc）',
                              icon: const Icon(
                                Icons.arrow_back_ios_new,
                                size: 15,
                              ),
                              color: soft,
                              visualDensity: VisualDensity.compact,
                              onPressed: () => Navigator.of(context).maybePop(),
                            ),
                            const SizedBox(width: 8),
                            Text('分组', style: theme.textTheme.titleMedium),
                            const Spacer(),
                            IconButton(
                              tooltip: '新建分组',
                              icon: const Icon(Icons.add, size: 17),
                              color: soft,
                              visualDensity: VisualDensity.compact,
                              onPressed: _create,
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(
                            '把条目分门别类。只分一层——一层就够用，'
                            '再多要点开好几次才能找到东西。',
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.6,
                              color: soft,
                            ),
                          ),
                        ),
                      ),
                      const Divider(height: 0.5),
                      Expanded(
                        child: groups.isEmpty
                            ? _emptyState(theme, soft)
                            : ListView.separated(
                                padding: const EdgeInsets.only(bottom: 64),
                                itemCount: groups.length,
                                separatorBuilder: (_, _) => const Divider(
                                  height: 0.5,
                                  indent: 24,
                                  endIndent: 24,
                                ),
                                itemBuilder: (_, i) => _groupRow(
                                  groups[i],
                                  theme,
                                  soft,
                                  faint,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _groupRow(
    KdbxGroup group,
    ThemeData theme,
    Color soft,
    Color faint,
  ) {
    final count = group.allEntries.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              group.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14.5),
            ),
          ),
          Text('$count 条', style: TextStyle(fontSize: 12, color: faint)),
          PopupMenuButton<String>(
            tooltip: '重命名或删除',
            icon: Icon(Icons.more_horiz, size: 16, color: faint),
            padding: EdgeInsets.zero,
            splashRadius: 16,
            onSelected: (value) {
              if (value == 'rename') {
                _rename(group);
              } else if (value == 'delete') {
                _delete(group);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'rename',
                height: 38,
                child: Text('改名字', style: TextStyle(fontSize: 13.5)),
              ),
              PopupMenuItem(
                value: 'delete',
                height: 38,
                child: Text('删掉分组', style: TextStyle(fontSize: 13.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _emptyState(ThemeData theme, Color soft) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '还没有分组',
              style: TextStyle(
                fontSize: 14,
                letterSpacing: 1.2,
                color: soft,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '右上角加一个。之后在列表顶上一划就能筛，\n条目也能随时挪来挪去。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.7, color: soft),
            ),
            const SizedBox(height: 22),
            TextButton(
              onPressed: _create,
              child: const Text('建一个分组', style: TextStyle(fontSize: 13.5)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 问名字的对话框。
///
/// 输入框控制器必须由**这个 State** 持有并释放：曾经写成
/// `showDialog(...).whenComplete(controller.dispose)`，结果对话框关闭时退场
/// 动画还在重建那个 TextField，于是撞上「controller used after disposed」。
/// 控制器活多久，得跟用它的那棵子树一样长。
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.confirm,
    this.initial,
  });

  final String title;
  final String confirm;
  final String? initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        style: const TextStyle(fontSize: 14.5),
        decoration: const InputDecoration(
          labelText: '分组名称',
          hintText: '工作、家里、银行卡…',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: Text(widget.confirm)),
      ],
    );
  }
}

/// 未 grouping 的占位名，列表与编辑页共用同一份文案。
const ungroupedLabel = '未分组';
