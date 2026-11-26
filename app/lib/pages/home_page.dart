import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kpasslib/kpasslib.dart';

import '../core/idle_guard.dart';
import '../core/password_gen.dart';
import '../core/vault_controller.dart';
import '../theme/app_theme.dart';

/// 便签式界面：打开即列表，点加号就能记，自动保存。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.vault, required this.idleGuard});

  final VaultController vault;
  final IdleGuard idleGuard;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _checking = true;
  String? _lastPath;
  bool _unlocked = false;
  bool _creating = false;
  bool _autoLocked = false;
  bool _locking = false;
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.vault.addListener(_onVault);
    widget.idleGuard.onIdle = _onIdle;
    _boot();
  }

  @override
  void dispose() {
    widget.vault.removeListener(_onVault);
    widget.idleGuard
      ..disarm()
      ..onIdle = null;
    _password.dispose();
    _confirm.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onVault() {
    if (mounted) setState(() {});
  }

  void _onIdle() {
    unawaited(_lock(auto: true));
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
      _autoLocked = false;
      _error = ok ? null : widget.vault.lastError;
    });
    if (ok) {
      _password.clear();
      widget.idleGuard.arm();
      _focusSearchSoon();
    }
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
      _autoLocked = false;
      _error = ok ? null : widget.vault.lastError;
    });
    if (ok) {
      _password.clear();
      _confirm.clear();
      widget.idleGuard.arm();
      _focusSearchSoon();
    }
  }

  /// 解锁后把光标放进搜索框：打开就能打字找东西，少一次点击。
  void _focusSearchSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  /// 锁定。先落盘再关库：正在编辑的内容不能因为「锁」而丢。
  Future<void> _lock({bool auto = false}) async {
    if (_locking || !_unlocked) return;
    _locking = true;
    widget.idleGuard.disarm();
    await widget.vault.flushNow();
    widget.vault.close();
    if (!mounted) {
      _locking = false;
      return;
    }
    // 编辑页可能还压在栈上：先回到首页，再显示锁定界面。
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() {
      _unlocked = false;
      _creating = false;
      _autoLocked = auto;
      _error = null;
      _query = '';
      _search.clear();
    });
    _locking = false;
  }

  Future<void> _newNote() async {
    final entry = widget.vault.addEntry();
    await _openEditor(entry);
  }

  /// Ctrl+F：聚焦搜索框并全选旧词，直接打字就是新查询。
  void _focusSearch() {
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已复制$label · 30 秒后自动清空')));
    Timer(const Duration(seconds: 30), () async {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == text) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 读偏好是毫秒级的事，别闪一个进度圈打断「打开就开始用」。
    if (_checking) return const Scaffold(body: SizedBox.expand());
    return _unlocked ? _listScaffold() : _lockedScaffold();
  }

  // ───────────────────────── 解锁 / 创建 ─────────────────────────

  Widget _lockedScaffold() {
    final hasVault = _lastPath != null && !_creating;
    final theme = Theme.of(context);
    final soft = theme.colorScheme.onSurfaceVariant;
    final faint = theme.textTheme.labelSmall?.color;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
          child: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 书脊上的烫印：这是整个应用唯一允许出现强调色的地方。
                Text(
                  'passbook',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 3.4,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 44),
                Text(
                  hasVault ? '输入主密码' : '设一个主密码',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  hasVault ? '这把钥匙只存在你这里' : '之后每次打开都用它。忘了就打不开了',
                  style: TextStyle(fontSize: 13, height: 1.5, color: soft),
                ),
                if (_autoLocked) ...[
                  const SizedBox(height: 4),
                  Text(
                    '无操作 ${widget.idleGuard.limit.inMinutes} 分钟，已自动锁定',
                    style: TextStyle(fontSize: 12, height: 1.5, color: faint),
                  ),
                ],
                const SizedBox(height: 32),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofocus: true,
                  enabled: !_busy,
                  style: const TextStyle(fontSize: 15, letterSpacing: 1.2),
                  onSubmitted: (_) => hasVault ? _unlock() : _create(),
                  decoration: const InputDecoration(
                    hintText: '主密码',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 2,
                    ),
                  ),
                ),
                if (!hasVault) ...[
                  const SizedBox(height: 18),
                  TextField(
                    controller: _confirm,
                    obscureText: true,
                    enabled: !_busy,
                    style: const TextStyle(fontSize: 15, letterSpacing: 1.2),
                    onSubmitted: (_) => _create(),
                    decoration: const InputDecoration(
                      hintText: '再输一次',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 2,
                      ),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                Row(
                  children: [
                    if (!hasVault && _lastPath != null)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _creating = false;
                                _error = null;
                              }),
                        style: TextButton.styleFrom(
                          foregroundColor: faint,
                          padding: EdgeInsets.zero,
                        ),
                        child: const Text(
                          '返回解锁',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      )
                    else if (hasVault)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _creating = true;
                                _error = null;
                              }),
                        style: TextButton.styleFrom(
                          foregroundColor: faint,
                          padding: EdgeInsets.zero,
                        ),
                        child: const Text(
                          '用别的库',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: _busy ? null : (hasVault ? _unlock : _create),
                      child: Text(hasVault ? '进入 →' : '创建 →'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ───────────────────────── 列表 ─────────────────────────

  Widget _listScaffold() {
    final entries = widget.vault.allEntries.where((entry) {
      if (_query.trim().isEmpty) return true;
      final q = _query.trim().toLowerCase();
      return widget.vault.fieldOf(entry, 'Title').toLowerCase().contains(q) ||
          widget.vault.fieldOf(entry, 'Notes').toLowerCase().contains(q) ||
          widget.vault.fieldOf(entry, 'UserName').toLowerCase().contains(q);
    }).toList();

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            unawaited(_newNote()),
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () =>
            unawaited(_lock()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                // 一栏到底：页眉、搜索、列表全部同轴。多一套左边缘，
                // 眼睛就要多校准一次——这是最常见的「生成感」来源。
                constraints: const BoxConstraints(maxWidth: Palette.listWidth),
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    children: [
                      _listHeader(entries.length),
                      _searchRow(),
                      const Divider(height: 0.5),
                      Expanded(
                        child: entries.isEmpty
                            ? _emptyState()
                            : ListView.separated(
                                padding: const EdgeInsets.only(
                                  top: 4,
                                  bottom: 96,
                                ),
                                itemCount: entries.length,
                                separatorBuilder: (_, _) => const Divider(
                                  height: 0.5,
                                  indent: 24,
                                  endIndent: 24,
                                ),
                                itemBuilder: (context, index) =>
                                    _noteRow(entries[index]),
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

  Widget _listHeader(int count) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 14, 8),
      child: Row(
        children: [
          Text(
            'passbook',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 3.4,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 14),
          Text('$count 条', style: theme.textTheme.labelSmall),
          const Spacer(),
          _quietIcon(
            icon: Icons.add,
            tooltip: '新建（Ctrl+N）',
            onPressed: () => unawaited(_newNote()),
          ),
          const SizedBox(width: 4),
          _quietIcon(
            icon: Icons.lock_outline,
            tooltip: '锁定（Ctrl+L）',
            onPressed: () => unawaited(_lock()),
          ),
        ],
      ),
    );
  }

  /// 图标是工具不是装饰：默认淡、悬停才实。密集的深色图标会把纸弄脏。
  Widget _quietIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      color: theme.colorScheme.onSurfaceVariant,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
    );
  }

  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
      child: TextField(
        controller: _search,
        focusNode: _searchFocus,
        onChanged: (value) => setState(() => _query = value),
        style: const TextStyle(fontSize: 14),
        cursorHeight: 15,
        decoration: const InputDecoration(
          hintText: '搜索',
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 6),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }

  Widget _noteRow(KdbxEntry entry) {
    final theme = Theme.of(context);
    final title = widget.vault.fieldOf(entry, 'Title');
    final preview = widget.vault.previewOf(entry);
    final hasPassword = widget.vault.hasPassword(entry);

    return InkWell(
      onTap: () => _openEditor(entry),
      // 悬停给一点点底色：回应人的动作，但别用 splash（纸上会显得脏）。
      hoverColor: theme.colorScheme.onSurface.withValues(alpha: 0.025),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 12, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty ? '无标题' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                      color: title.isEmpty
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  if (preview.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (hasPassword)
              _quietIcon(
                icon: Icons.key_outlined,
                tooltip: '复制密码',
                onPressed: () => unawaited(
                  _copy(widget.vault.fieldOf(entry, 'Password'), '密码'),
                ),
              )
            else
              const SizedBox(width: 34),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '还什么都没记',
            style: TextStyle(
              fontSize: 13.5,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => unawaited(_newNote()),
            child: const Text('记第一条'),
          ),
        ],
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
  bool _showSecret = false;
  bool _reveal = false;

  /// 字段自己不带边框：这里的排版靠留白与字号，不靠框。
  static const _bare = InputDecoration(
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    contentPadding: EdgeInsets.zero,
    isDense: true,
  );

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _title = TextEditingController(text: widget.vault.fieldOf(e, 'Title'));
    _body = TextEditingController(text: widget.vault.fieldOf(e, 'Notes'));
    _username = TextEditingController(
      text: widget.vault.fieldOf(e, 'UserName'),
    );
    _password = TextEditingController(
      text: widget.vault.fieldOf(e, 'Password'),
    );
    _url = TextEditingController(text: widget.vault.fieldOf(e, 'URL'));
    _showSecret = _password.text.isNotEmpty;
    _title.addListener(_onEdit);
    _body.addListener(_onEdit);
    _username.addListener(_onEdit);
    _password.addListener(_onEdit);
    _url.addListener(_onEdit);
  }

  @override
  void dispose() {
    // 改动先进内存，落盘防抖在 controller 里；这里负责让「返回列表」也把
    // 挂起的那一次写落下去——否则快速输入后立刻返回会丢最后几个字。
    unawaited(widget.vault.flushNow());
    _title.dispose();
    _body.dispose();
    _username.dispose();
    _password.dispose();
    _url.dispose();
    super.dispose();
  }

  void _onEdit() {
    final e = widget.entry;
    widget.vault.updateField(e, 'Title', _title.text);
    widget.vault.updateField(e, 'Notes', _body.text);
    widget.vault.updateField(e, 'UserName', _username.text);
    widget.vault.updateField(e, 'Password', _password.text);
    widget.vault.updateField(e, 'URL', _url.text);
    widget.vault.scheduleSave();
  }

  /// 一键生成：不弹选项面板。要「换一个」就再点一次，比多选题快。
  void _generate() {
    final pwd = PasswordGenerator.generate();
    _password.text = pwd; // 触发 listener → 落内存 + scheduleSave
    setState(() => _reveal = true); // 生成即显示：主人要把它抄到别处
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已生成 20 位密码'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条？'),
        content: const Text('删掉就找不回来了。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              '取消',
              style: TextStyle(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.vault.flushNow();
    widget.vault.deleteEntry(widget.entry);
    await widget.vault.save();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                // 行宽上限：超过这个宽度眼睛跳行，是桌面排版最常见的缺陷。
                // 顶栏也锁进同一条轴，否则返回键会孤零零地飘在窗口最左。
                constraints: const BoxConstraints(
                  maxWidth: Palette.readingWidth,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    children: [
                      _editorBar(theme),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(32, 12, 32, 96),
                          children: [
                            TextField(
                              controller: _title,
                              autofocus: _title.text.isEmpty,
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w500,
                                letterSpacing: -0.3,
                                height: 1.25,
                              ),
                              cursorHeight: 26,
                              decoration: _bare.copyWith(hintText: '标题'),
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: _body,
                              maxLines: null,
                              minLines: 3,
                              keyboardType: TextInputType.multiline,
                              style: const TextStyle(
                                fontSize: 15.5,
                                height: 1.85,
                              ),
                              cursorHeight: 17,
                              decoration: _bare.copyWith(hintText: '记点什么'),
                            ),
                            const SizedBox(height: 36),
                            if (!_showSecret)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: () =>
                                      setState(() => _showSecret = true),
                                  icon: const Icon(Icons.add, size: 15),
                                  label: const Text('账号密码'),
                                  style: TextButton.styleFrom(
                                    foregroundColor:
                                        theme.colorScheme.onSurfaceVariant,
                                    padding: EdgeInsets.zero,
                                    textStyle: const TextStyle(fontSize: 13.5),
                                  ),
                                ),
                              )
                            else ...[
                              // 小标题接一根线：不是装饰，是在说「从这里开始是
                              // 另一类信息」。三行裸字段没有归属，读者要自己猜。
                              Row(
                                children: [
                                  Text(
                                    '登录信息',
                                    style: TextStyle(
                                      fontSize: 11,
                                      letterSpacing: 0.8,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Divider(
                                      height: 0.5,
                                      color: theme.colorScheme.outline,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              _secretField(
                                controller: _username,
                                hint: '用户名 / 邮箱',
                              ),
                              const SizedBox(height: 18),
                              TextField(
                                controller: _password,
                                obscureText: !_reveal,
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  height: 1.4,
                                  letterSpacing: 0.6,
                                  fontFamily: 'Consolas',
                                ),
                                decoration: _bare.copyWith(
                                  hintText: '密码',
                                  suffixIcon: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: '生成 20 位密码',
                                        icon: const Icon(
                                          Icons.casino_outlined,
                                          size: 16,
                                        ),
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                        onPressed: _generate,
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      IconButton(
                                        tooltip: _reveal ? '隐藏' : '显示',
                                        icon: Icon(
                                          _reveal
                                              ? Icons.visibility_off_outlined
                                              : Icons.visibility_outlined,
                                          size: 16,
                                        ),
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                        onPressed: () =>
                                            setState(() => _reveal = !_reveal),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 18),
                              _secretField(controller: _url, hint: '网址'),
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
        ),
      ),
    );
  }

  Widget _secretField({
    required TextEditingController controller,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontSize: 14.5, height: 1.4),
      decoration: _bare.copyWith(hintText: hint),
    );
  }

  Widget _editorBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回（Esc）',
            icon: const Icon(Icons.arrow_back_ios_new, size: 15),
            color: theme.colorScheme.onSurfaceVariant,
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const Spacer(),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: Icon(
              Icons.more_horiz,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            onSelected: (value) {
              if (value == 'delete') unawaited(_delete());
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'delete',
                child: Text(
                  '删除这条',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
