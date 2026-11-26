import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kpasslib/kpasslib.dart';

import '../core/biometric.dart';
import '../core/idle_guard.dart';
import '../core/password_gen.dart';
import '../core/totp.dart';
import '../core/update/update_controller.dart';
import '../core/vault_controller.dart';
import '../theme/app_theme.dart';
import 'about_page.dart';
import 'backup_page.dart';
import 'group_page.dart';
import 'sync_page.dart';

/// 便签式界面：打开即列表，点加号就能记，自动保存。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.vault,
    required this.idleGuard,
    this.updates,
    this.biometric,
  });

  final VaultController vault;
  final IdleGuard idleGuard;

  /// 自动更新的状态源。为 null 时页面上不出现更新入口——
  /// 单元测试不需要为了一个图标去造一个真发 HTTP 的控制器。
  final UpdateController? updates;

  /// 指纹解锁。为 null 时整套入口都不出现，退化成纯密码解锁——
  /// 设备没有生物识别硬件、或单元测试里不想碰平台通道，都走这条路。
  final BiometricUnlock? biometric;

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

  /// 最近一次在条目上按下的位置。长按回调本身不带坐标，而菜单要出现在
  /// 手指（或光标）那儿——长按必然先经过按下，所以记这一格就够。
  Offset _notePressure = Offset.zero;

  /// 这台设备有没有可用的生物识别。关的时候也留着它——
  /// 「能力」与「选择」是两件事：关掉指纹不等于硬件消失了。
  bool _bioSupported = false;

  /// 指纹解锁是不是开着。以密钥库里有没有那份密码为准（每次从磁盘复读）。
  bool _bioEnabled = false;
  bool _bioBusy = false;
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  /// 当前筛的分组；null = 全部。按 uuid 记而不是按对象记：分组被删掉重建
  /// 之后对象会变，uuid 才认得出「还是不是同一个」。
  KdbxUuid? _groupFilterId;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.vault.addListener(_onVault);
    widget.idleGuard.onIdle = _onIdle;
    widget.updates?.addListener(_onUpdates);
    _boot();
  }

  void _onUpdates() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.vault.removeListener(_onVault);
    widget.updates?.removeListener(_onUpdates);
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
    final bio = widget.biometric;
    var supported = false;
    var enabled = false;
    if (bio != null) {
      // supported 与 enabled 分开问：前者是「硬件在不在」，后者是「开没开」。
      supported = await bio.isSupported();
      enabled = supported && await bio.isEnabled();
    }
    if (!mounted) return;
    setState(() {
      _lastPath = path;
      _bioSupported = supported;
      _bioEnabled = enabled;
      _checking = false;
    });
    // 开过指纹、库也在：启动就直接问，按一下就进去（不用先看一眼密码框）。
    if (enabled && path != null) {
      unawaited(_unlockWithBiometric(auto: true));
    }
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
      final used = _password.text;
      _password.clear();
      widget.idleGuard.arm();
      _focusSearchSoon();
      _offerBiometric(used);
    }
  }

  /// 用指纹取主密码来开库。
  ///
  /// [auto] 是「启动时自动试一次」的意思：那时候用户还没表达意图，
  /// 所以取消、验证不过、读不出来都**静默退回手输**，不弹错误。
  Future<void> _unlockWithBiometric({bool auto = false}) async {
    final bio = widget.biometric;
    final path = _lastPath;
    if (bio == null || path == null || _busy || _bioBusy) return;
    setState(() {
      _bioBusy = true;
      if (!auto) _error = null;
    });
    final saved = await bio.takePassword();
    if (!mounted) return;
    if (saved == null) {
      setState(() => _bioBusy = false);
      return;
    }
    final ok = await widget.vault.open(path, saved);
    if (!mounted) return;
    if (!ok) {
      // 存的密码打不开这个库：改过主密码，或者换了一个库。
      // 留着它只会让之后每次指纹解锁都注定失败，还要多等一次验证——清掉，说清楚。
      await bio.forget();
      if (!mounted) return;
      setState(() {
        _bioBusy = false;
        _bioEnabled = false;
        _error = '指纹里存的那份密码打不开这个库，已关掉指纹解锁。请输入主密码';
      });
      return;
    }
    setState(() {
      _bioBusy = false;
      _unlocked = true;
      _autoLocked = false;
      _error = null;
    });
    widget.idleGuard.arm();
    _focusSearchSoon();
  }

  /// 密码刚验对的那一刻问一句要不要开指纹。
  ///
  /// 只在这一刻问是有原因的：此时主密码就在手上，存进密钥库不需要他再输一遍。
  /// 用提示条而不是对话框——不打断，也不要他先回答才能继续用。
  void _offerBiometric(String password) {
    final bio = widget.biometric;
    if (bio == null || _bioEnabled || !_bioSupported || password.isEmpty) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('要不要开启指纹解锁？之后按一下就进'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: '开启',
          onPressed: () => unawaited(_enableBiometric(bio, password)),
        ),
      ),
    );
  }

  /// 开启指纹：先验证一次（证明是本人），再把密码存进系统密钥库。
  Future<void> _enableBiometric(BiometricUnlock bio, String password) async {
    final ok = await bio.enable(password);
    if (!mounted) return;
    setState(() => _bioEnabled = ok);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已开启指纹解锁' : '没能开启指纹解锁'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 关掉指纹（关于页用）。关掉之后那份密码就没了，下次要手输。
  Future<void> setBiometricEnabled(bool value) async {
    final bio = widget.biometric;
    if (bio == null) return;
    if (value) {
      // 开启需要主密码，而这里拿不到——只能走「解锁成功时的提示」那条路。
      // 所以这里只做关闭，开启方向如实返回（界面上也会说明）。
      return;
    }
    await bio.disable();
    if (!mounted) return;
    setState(() => _bioEnabled = false);
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
      // 库放在哪必须让他知道：目录可能不是他默认以为的那一个。
      final where = widget.vault.filePath;
      if (where != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('库已建在 $where'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    }
  }

  /// 解锁后把光标放进搜索框：打开就能打字找东西，少一次点击。
  ///
  /// **只在桌面端这么做。** 触屏上「聚焦输入框」就等于「弹出软键盘」，它一出现
  /// 就盖住半屏列表——那不是省一次点击，是每次打开都先关一次键盘。
  void _focusSearchSoon() {
    if (!_hasPointerKeyboard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  /// 这台设备有没有物理键盘可指望。桌面端算有；安卓外接键盘的情况代价只是
  /// 少一次快捷键，比每次都挡半屏轻得多。
  bool get _hasPointerKeyboard =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

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
    // 正筛着某个分组时，新建的条目直接进那个组——否则记完还得再挪一次。
    final entry = widget.vault.addEntry(parent: _filteredGroup());
    await _openEditor(entry);
  }

  /// 当前筛的分组；筛的组已经被删掉时返回 null（当作「全部」）。
  KdbxGroup? _filteredGroup() {
    final id = _groupFilterId;
    if (id == null) return null;
    for (final group in widget.vault.groups) {
      if (group.uuid == id) return group;
    }
    return null;
  }

  Future<void> _openGroups() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => GroupPage(vault: widget.vault)),
    );
    if (mounted) setState(() {});
  }

  /// Ctrl+F：聚焦搜索框并全选旧词，直接打字就是新查询。
  void _focusSearch() {
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
  }

  /// Esc / 点 ×：清空查询并把焦点交还列表，键盘跟着收起来。
  void _clearSearch() {
    if (_query.isEmpty && _search.text.isEmpty) return;
    _search.clear();
    _searchFocus.unfocus();
    setState(() => _query = '');
  }

  Future<void> _openEditor(KdbxEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(vault: widget.vault, entry: entry),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openSync() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SyncPage(vault: widget.vault)));
    // 同步会合并出对端的条目，回来得重读列表。
    if (mounted) setState(() {});
  }

  Future<void> _openBackup() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => BackupPage(vault: widget.vault)),
    );
    // 恢复会整个换掉库里的内容，回来必须重读。
    if (mounted) setState(() {});
  }

  Future<void> _openAbout() async {
    final updates = widget.updates;
    if (updates == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AboutPage(
          updates: updates,
          biometric: widget.biometric,
          // 关于页可能把指纹关掉了——回来要重读，锁屏页那个按钮依赖它。
          onBiometricChanged: () => unawaited(_refreshBiometric()),
        ),
      ),
    );
  }

  /// 从磁盘复读指纹开关状态。不信内存：别的地方（关于页）可能刚改过。
  Future<void> _refreshBiometric() async {
    final bio = widget.biometric;
    if (bio == null) return;
    final on = await bio.isEnabled();
    if (!mounted) return;
    setState(() => _bioEnabled = on);
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

  // ───────────────────── 条目菜单（右键 / 长按） ─────────────────────

  /// 条目菜单。桌面端右键、安卓长按，同一个入口。
  ///
  /// 菜单项按「这条有没有那个字段」出：空的复制项不给位置。删除放在最下面
  /// 并标红——它是这一屏唯一不可逆的动作。
  Future<void> _showEntryMenu(KdbxEntry entry, Offset position) async {
    // 先收掉输入焦点。搜索框是这一屏唯一的可聚焦控件，菜单/对话框关掉时
    // 焦点会回落到它身上、把键盘顶出来——而人此刻想看的是列表。
    FocusScope.of(context).unfocus();
    final vault = widget.vault;
    final username = vault.fieldOf(entry, 'UserName');
    final password = vault.fieldOf(entry, 'Password');
    final url = vault.fieldOf(entry, 'URL');
    final hasAnySecret =
        username.isNotEmpty || password.isNotEmpty || url.isNotEmpty;
    final size = MediaQuery.sizeOf(context);

    final action = await showMenu<_EntryAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx.clamp(0.0, size.width),
        position.dy.clamp(0.0, size.height),
        (size.width - position.dx).clamp(0.0, size.width),
        (size.height - position.dy).clamp(0.0, size.height),
      ),
      items: [
        // 最常用的放最上：打开菜单的人十次有八次是要抄密码。
        if (password.isNotEmpty)
          _menuItem(_EntryAction.copyPassword, Icons.key_outlined, '复制密码'),
        if (username.isNotEmpty)
          _menuItem(_EntryAction.copyUsername, Icons.person_outline, '复制用户名'),
        if (url.isNotEmpty) _menuItem(_EntryAction.copyUrl, Icons.link, '复制网址'),
        if (hasAnySecret) const PopupMenuDivider(),
        _menuItem(_EntryAction.edit, Icons.edit_outlined, '编辑'),
        // 一个分组都没有时也给这一项：对话框里会告诉你去哪建。菜单里突然
        // 少一项，人的第一反应是「刚才那个能点去哪了」。
        _menuItem(_EntryAction.moveToGroup, Icons.folder_outlined, '移到分组'),
        const PopupMenuDivider(),
        _menuItem(
          _EntryAction.delete,
          Icons.delete_outline,
          '删除',
          danger: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _EntryAction.copyPassword:
        await _copy(password, '密码');
      case _EntryAction.copyUsername:
        await _copy(username, '用户名');
      case _EntryAction.copyUrl:
        await _copy(url, '网址');
      case _EntryAction.edit:
        await _openEditor(entry);
      case _EntryAction.moveToGroup:
        await _moveEntryToGroup(entry);
      case _EntryAction.delete:
        await _confirmDeleteEntry(entry);
    }
  }

  PopupMenuItem<T> _menuItem<T>(
    T value,
    IconData icon,
    String label, {
    bool danger = false,
  }) {
    final theme = Theme.of(context);
    return PopupMenuItem<T>(
      value: value,
      height: 44,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: danger ? theme.colorScheme.error : theme.hintColor,
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              color: danger
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _moveEntryToGroup(KdbxEntry entry) async {
    final vault = widget.vault;
    final current = vault.groupOf(entry);
    final picked = await showGroupPicker(context, vault, current);
    if (!mounted || picked == null) return;
    final groups = vault.groups;
    final target = (picked == 0 || picked > groups.length)
        ? null
        : groups[picked - 1];
    if (target?.uuid == current?.uuid) return;
    vault.moveEntry(entry, target);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已移到${target?.name ?? ungroupedLabel}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _confirmDeleteEntry(KdbxEntry entry) async {
    // 标题写进问句里：列表里相邻两条长得像的时候，只问「删除这条？」等于
    // 让人凭记忆确认。说清是哪一条，误删才拦得住。
    final title = widget.vault.fieldOf(entry, 'Title').trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title.isEmpty ? '删除这条？' : '删除「$title」？'),
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
    if (confirmed != true || !mounted) return;
    final vault = widget.vault;
    await vault.flushNow();
    vault.deleteEntry(entry);
    await vault.save();
    if (mounted) setState(() {});
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
                // 开了指纹之后，这一行是第一选择；密码框仍然在，随时可以改用它。
                if (hasVault && _bioEnabled) ...[
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: (_busy || _bioBusy)
                        ? null
                        : () => unawaited(_unlockWithBiometric()),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      foregroundColor: theme.colorScheme.primary,
                    ),
                    icon: const Icon(Icons.fingerprint, size: 17),
                    label: Text(
                      _bioBusy ? '验证中…' : '用指纹解锁',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
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
    // 分层取数：先按分组筛出这一屏的范围，再按搜索词过滤。两层分开是因为
    // 空态要说的话不一样——「这个分组还空着」和「没有匹配的条目」是两回事。
    final inGroup = widget.vault.entriesOf(_filteredGroup());
    final entries = inGroup.where((entry) {
      if (_query.trim().isEmpty) return true;
      final q = _query.trim().toLowerCase();
      return widget.vault.fieldOf(entry, 'Title').toLowerCase().contains(q) ||
          widget.vault.fieldOf(entry, 'Notes').toLowerCase().contains(q) ||
          widget.vault.fieldOf(entry, 'UserName').toLowerCase().contains(q);
    }).toList();

    return PopScope(
      // 安卓习惯：正筛着分组或搜着东西时，返回键先退回「全部」，而不是直接
      // 退出应用。直接退的话，人刚点进 Work 再按返回就没了——那是最容易被
      // 骂「这软件怎么老自己关」的一种。
      canPop: _groupFilterId == null && _query.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_query.isNotEmpty) {
          _clearSearch();
        } else {
          setState(() => _groupFilterId = null);
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _focusSearch,
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
              unawaited(_newNote()),
          const SingleActivator(LogicalKeyboardKey.keyL, control: true): () =>
              unawaited(_lock()),
          const SingleActivator(LogicalKeyboardKey.escape): _clearSearch,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  // 一栏到底：页眉、搜索、列表全部同轴。多一套左边缘，
                  // 眼睛就要多校准一次——这是最常见的「生成感」来源。
                  constraints: const BoxConstraints(
                    maxWidth: Palette.listWidth,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: Column(
                      children: [
                        _listHeader(entries.length, total: inGroup.length),
                        _searchRow(),
                        _groupBar(),
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
      ),
    );
  }

  Widget _listHeader(int count, {required int total}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 14, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 窄屏（手机竖屏 360dp）不显示品牌名：它只是个标记，不是信息，该给
          // 工具按钮让位。六个图标在 360dp 上加上它就是溢出十几像素——而这种
          // 溢出只有真机上才看得见，靠算间距迟早会再撞一次。
          final showBrand = constraints.maxWidth >= 420;
          return Row(
            children: [
              if (showBrand) ...[
                Text(
                  'passbook',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 3.4,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              // 筛着东西时把总量也报出来：只写「1 条」会让人以为库里只剩一条。
              Text(
                count == total ? '$count 条' : '$count / $total 条',
                style: theme.textTheme.labelSmall,
              ),
              const Spacer(),
              if (widget.updates?.hasUpdate ?? false) _updateHint(theme),
              _quietIcon(
                icon: Icons.sync_alt,
                tooltip: '局域网同步',
                onPressed: () => unawaited(_openSync()),
              ),
              const SizedBox(width: 2),
              _quietIcon(
                icon: Icons.archive_outlined,
                tooltip: '备份与恢复',
                onPressed: () => unawaited(_openBackup()),
              ),
              const SizedBox(width: 2),
              _quietIcon(
                icon: Icons.folder_outlined,
                tooltip: '分组整理',
                onPressed: () => unawaited(_openGroups()),
              ),
              const SizedBox(width: 2),
              _quietIcon(
                icon: Icons.add,
                tooltip: '新建（Ctrl+N）',
                onPressed: () => unawaited(_newNote()),
              ),
              const SizedBox(width: 2),
              _quietIcon(
                icon: Icons.lock_outline,
                tooltip: '锁定（Ctrl+L）',
                onPressed: () => unawaited(_lock()),
              ),
              const SizedBox(width: 2),
              _quietIcon(
                icon: Icons.info_outline,
                tooltip: '关于与更新',
                onPressed: () => unawaited(_openAbout()),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 有新版时先在列表头上说一句，而不是弹窗打断解锁后的第一眼。
  /// 它只是入口：点进去才是「关于与更新」那一页。
  Widget _updateHint(ThemeData theme) {
    final tag = widget.updates?.release?.tag;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: () => unawaited(_openAbout()),
        borderRadius: BorderRadius.circular(Palette.radius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                '新版 ${tag ?? ''}',
                style: TextStyle(
                  fontSize: 11.5,
                  letterSpacing: 0.2,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
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
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
    );
  }

  /// 分组筛选条。一个分组都没有时整条不出现——空工具栏只会让人多点一次，
  /// 还会把「这里原本有一行内容」的留白抢掉。
  Widget _groupBar() {
    final groups = widget.vault.groups;
    if (groups.isEmpty) return const SizedBox.shrink();
    final current = _filteredGroup();
    // 高度交给内容决定。曾经写成固定 36 高的横向 ListView，结果 Windows 上
    // 「默认分组」的下半截被裁掉——中文字形比拉丁字母高，行高一旦超过那个
    // 固定值，ListView 就会硬裁（clipBehavior 默认 hardEdge）。
    //
    // 另外必须自己撑满宽度：外面的 Column 横向默认居中，而 SingleChildScrollView
    // 只肯索取内容宽度 ⇒ 不撑满时整排分组名会跑到屏幕正中间，跟列表的左边缘脱开。
    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
        child: Row(
          children: [
            _groupChip(
              label: '全部',
              selected: current == null,
              onTap: () => setState(() => _groupFilterId = null),
            ),
            for (final group in groups)
              _groupChip(
                label: group.name,
                count: group.allEntries.length,
                selected: current?.uuid == group.uuid,
                onTap: () => setState(() => _groupFilterId = group.uuid),
                onMenu: (position) =>
                    unawaited(_showGroupMenu(group, position)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _groupChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    int? count,
    void Function(Offset position)? onMenu,
  }) {
    final theme = Theme.of(context);
    final soft = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      // 用 Builder 拿这个 chip 自己的坐标：菜单要落在它下面一点，
      // 而不是落在屏幕某处——多个 chip 共用一份状态会互相抢位置。
      child: Builder(
        builder: (chipContext) => InkWell(
          onTap: onTap,
          onLongPress: onMenu == null
              ? null
              : () => onMenu(_anchorBelow(chipContext)),
          onSecondaryTapDown: onMenu == null
              ? null
              : (d) => onMenu(d.globalPosition),
          borderRadius: BorderRadius.circular(Palette.radius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: selected ? theme.colorScheme.primary : soft,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                if (count != null && count > 0) ...[
                  const SizedBox(width: 5),
                  Text(
                    '$count',
                    style: TextStyle(fontSize: 11, color: theme.hintColor),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 某个控件正下方的那个点——长按弹菜单用它当锚点，菜单就不盖住被按的东西。
  Offset _anchorBelow(BuildContext ctx) {
    final box = ctx.findRenderObject();
    if (box is! RenderBox) return Offset.zero;
    final origin = box.localToGlobal(Offset.zero);
    return Offset(origin.dx, origin.dy + box.size.height);
  }

  /// 分组条上右键 / 长按：改名、删掉。
  ///
  /// 与分组页里的那两个操作是同一套实现（[askGroupName] / [confirmDeleteGroup]），
  /// 这里只是把它们搬到手边——整理分组不该每次都要先跳进一个二级页。
  Future<void> _showGroupMenu(KdbxGroup group, Offset position) async {
    FocusScope.of(context).unfocus();
    final size = MediaQuery.sizeOf(context);
    final action = await showMenu<_GroupAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx.clamp(0.0, size.width),
        position.dy.clamp(0.0, size.height),
        (size.width - position.dx).clamp(0.0, size.width),
        (size.height - position.dy).clamp(0.0, size.height),
      ),
      items: [
        _menuItem(_GroupAction.rename, Icons.edit_outlined, '改名'),
        const PopupMenuDivider(),
        _menuItem(
          _GroupAction.delete,
          Icons.delete_outline,
          '删除分组',
          danger: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _GroupAction.rename:
        final name = await askGroupName(
          context,
          title: '改个名字',
          confirm: '改好',
          initial: group.name,
        );
        if (name == null) return;
        widget.vault.renameGroup(group, name);
        setState(() {});
      case _GroupAction.delete:
        if (!await confirmDeleteGroup(context, group)) return;
        // 正筛着这个分组时先退回「全部」：否则筛的组没了，列表会突然空掉。
        if (_groupFilterId == group.uuid) _groupFilterId = null;
        widget.vault.deleteGroup(group);
        setState(() {});
    }
  }

  Widget _searchRow() {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, _query.isEmpty ? 24 : 12, 6),
      child: Row(
        children: [
          Expanded(
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
          ),
          // 只在真能清的时候出现：常驻的 × 是个噪音，它没有别的作用。
          if (_query.isNotEmpty)
            IconButton(
              onPressed: _clearSearch,
              tooltip: '清除（Esc）',
              iconSize: 15,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              splashRadius: 15,
              icon: Icon(Icons.close, color: theme.hintColor),
            ),
        ],
      ),
    );
  }

  Widget _noteRow(KdbxEntry entry) {
    final theme = Theme.of(context);
    final title = widget.vault.fieldOf(entry, 'Title');
    final preview = widget.vault.previewOf(entry);
    final hasPassword = widget.vault.hasPassword(entry);
    // 只在「全部」视图里缀分组名：已经按分组筛着的时候，每一行都写着同一个
    // 名字，那不是信息，是噪音。
    final groupName = _groupFilterId == null
        ? widget.vault.groupOf(entry)?.name
        : null;

    return InkWell(
      onTap: () => _openEditor(entry),
      onTapDown: (d) => _notePressure = d.globalPosition,
      onLongPress: () => unawaited(_showEntryMenu(entry, _notePressure)),
      // 桌面端右键、安卓长按：手势不同，动词相同，共用一份菜单。
      // 写成两份迟早会缺项——而缺的那一项只有用户碰上才发现。
      onSecondaryTapDown: (d) =>
          unawaited(_showEntryMenu(entry, d.globalPosition)),
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
                  if (preview.isNotEmpty || groupName != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      // 分组名缀在预览后面，不另起一行：多一行会让每条记录都变高，
                      // 而它是收件箱式列表，一屏能多看几条比什么都重要。
                      groupName == null
                          ? preview
                          : (preview.isEmpty
                                ? groupName
                                : '$preview · $groupName'),
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
    final query = _query.trim();
    final group = _filteredGroup();

    // 三种空是不一样的事：搜不到、这个分组还空着、整个库都还空着。
    // 一律写「还什么都没记」是在骗人——尤其搜不到的时候，人以为自己的条目没了。
    final String line;
    final String action;
    final VoidCallback onPressed;
    if (query.isNotEmpty) {
      line = '没有匹配「$query」的条目';
      action = '清除搜索';
      onPressed = _clearSearch;
    } else if (group != null) {
      line = '「${group.name}」还空着';
      action = '记第一条进来';
      onPressed = () => unawaited(_newNote());
    } else {
      line = '还什么都没记';
      action = '记第一条';
      onPressed = () => unawaited(_newNote());
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            line,
            style: TextStyle(
              fontSize: 13.5,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          TextButton(onPressed: onPressed, child: Text(action)),
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

  /// 动态验证码（TOTP）。`otp` 字段里存的是 otpauth 链接原文，
  /// [TotpConfig] 只是它解析出来的样子——永远以字段为准，不另存一份配置，
  /// 否则同步到别的设备改了密钥，本地这份就悄悄过时了。
  static const _otpField = 'otp';
  final TextEditingController _otpInput = TextEditingController();
  TotpConfig? _otp;
  String? _otpError;
  bool _otpEditing = false;
  String _otpCode = '';
  int _otpRemaining = 0;
  Timer? _otpTicker;

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
    _loadOtp();
  }

  /// 从字段读一次动态验证码配置。密钥本身不存在 State 里，只存在 KDBX 字段里。
  void _loadOtp() {
    final raw = widget.vault.fieldOf(widget.entry, _otpField);
    if (raw.trim().isEmpty) {
      // 字段空着是「还没设置」，不是错误——不显示红字。
      _otp = null;
      _otpError = null;
    } else {
      final parsed = parseTotp(raw);
      _otp = parsed.config;
      _otpError = parsed.isOk ? null : parsed.error;
    }
    _refreshOtpValues();
    _startOtpTicker();
  }

  void _refreshOtpValues() {
    final config = _otp;
    if (config == null) {
      _otpCode = '';
      _otpRemaining = 0;
      return;
    }
    final now = DateTime.now();
    _otpCode = config.codeAt(now);
    _otpRemaining = config.remainingAt(now);
  }

  /// 每秒刷新一次。只在有配置时跑，退出编辑页就停——一个看不见的定时器
  /// 每秒唤醒一次界面，是没有理由一直付的代价。
  void _startOtpTicker() {
    _otpTicker?.cancel();
    _otpTicker = null;
    if (_otp == null) return;
    _otpTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(_refreshOtpValues);
    });
  }

  @override
  void dispose() {
    // 改动先进内存，落盘防抖在 controller 里；这里负责让「返回列表」也把
    // 挂起的那一次写落下去——否则快速输入后立刻返回会丢最后几个字。
    unawaited(widget.vault.flushNow());
    _otpTicker?.cancel();
    _otpTicker = null;
    _title.dispose();
    _body.dispose();
    _username.dispose();
    _password.dispose();
    _url.dispose();
    _otpInput.dispose();
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

  // ---- 动态验证码 ----

  /// 存的是**原文**（otpauth 链接或裸密钥），解析只是为了让界面能显示码。
  /// 存解析后的参数就麻烦了：链接里可能有别的客户端认得的参数，我们看不懂，
  /// 但原样保存对端就还认。
  void _saveOtp() {
    final parsed = parseTotp(_otpInput.text);
    if (!parsed.isOk) {
      setState(() => _otpError = parsed.error);
      return;
    }
    final raw = _otpInput.text.trim();
    widget.vault.updateField(widget.entry, _otpField, raw);
    widget.vault.scheduleSave();
    setState(() {
      _otp = parsed.config;
      _otpError = null;
      _otpEditing = false;
      _otpInput.clear();
      _refreshOtpValues();
    });
    _startOtpTicker();
  }

  void _cancelOtpEdit() {
    setState(() {
      _otpEditing = false;
      _otpError = null;
      _otpInput.clear();
    });
  }

  Future<void> _removeOtp() async {
    // 密钥删掉就再也算不出来了（除非别处还留着），值一行确认。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删掉这个验证码？'),
        content: const Text('密钥会被清掉。之后要再用，得重新从网站上拿一次密钥。'),
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
    widget.vault.updateField(widget.entry, _otpField, '');
    widget.vault.scheduleSave();
    _otpTicker?.cancel();
    _otpTicker = null;
    setState(() {
      _otp = null;
      _otpError = null;
      _otpCode = '';
      _otpRemaining = 0;
    });
  }

  Future<void> _copyCode() async {
    final code = _otpCode.replaceAll(' ', '');
    if (code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('验证码已复制'), duration: Duration(seconds: 2)),
    );
  }

  /// 六位分两段、八位分两段：一眼能读完，也不会抄错位。
  static String _groupedCode(String code) {
    if (code.length < 6) return code;
    final half = code.length ~/ 2;
    return '${code.substring(0, half)} ${code.substring(half)}';
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
                            _groupRow(theme),
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
                            const SizedBox(height: 36),
                            _otpSection(theme),
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

  /// 小标题 + 一条细线。不是装饰：它在说「从这里开始是另一类信息」。
  Widget _ruleLabel(String text, ThemeData theme) {
    return Row(
      children: [
        Text(
          text,
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

  /// 分组一行，放在标题下面。
  ///
  /// 不塞进底部的附加信息里：它决定这条在列表里归哪儿，是打开就该看见的属性，
  /// 不是写完才想起来补的字段。
  Widget _groupRow(ThemeData theme) {
    final group = widget.vault.groupOf(widget.entry);
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: _pickGroup,
        borderRadius: BorderRadius.circular(Palette.radius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_outlined, size: 13, color: theme.hintColor),
              const SizedBox(width: 6),
              Text(
                group?.name ?? ungroupedLabel,
                style: TextStyle(
                  fontSize: 12.5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Icon(Icons.expand_more, size: 15, color: theme.hintColor),
            ],
          ),
        ),
      ),
    );
  }

  /// 选分组，选完这一行跟着变。对话框本体与列表页共用（见 [showGroupPicker]），
  /// 一处改两处生效——分成两份迟早一份改了另一份没改。
  Future<void> _pickGroup() async {
    final vault = widget.vault;
    final groups = vault.groups;
    final current = vault.groupOf(widget.entry);
    final picked = await showGroupPicker(context, vault, current);
    if (picked == null || !mounted) return;
    final target = (picked == 0 || picked > groups.length)
        ? null
        : groups[picked - 1];
    if (target?.uuid == current?.uuid) return;
    vault.moveEntry(widget.entry, target);
    setState(() {});
  }

  Widget _otpSection(ThemeData theme) {
    if (_otpEditing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ruleLabel('动态验证码', theme),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('otp-input'),
            controller: _otpInput,
            autofocus: true,
            minLines: 1,
            maxLines: 3,
            style: const TextStyle(
              fontSize: 13,
              height: 1.5,
              fontFamily: 'Consolas',
            ),
            decoration: _bare.copyWith(hintText: '粘贴 otpauth:// 链接，或直接给密钥'),
            onSubmitted: (_) => _saveOtp(),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton(onPressed: _saveOtp, child: const Text('保存')),
              const SizedBox(width: 4),
              TextButton(
                onPressed: _cancelOtpEdit,
                child: Text(
                  '取消',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          if (_otpError != null) ...[
            const SizedBox(height: 6),
            Text(
              _otpError!,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      );
    }

    final config = _otp;
    if (config == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('otp-add'),
          onPressed: () => setState(() => _otpEditing = true),
          icon: const Icon(Icons.add, size: 15),
          label: const Text('动态验证码'),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurfaceVariant,
            padding: EdgeInsets.zero,
            textStyle: const TextStyle(fontSize: 13.5),
          ),
        ),
      );
    }

    // 最后五秒变色：码要换了却不知道，是最常见的一类「怎么又不对」。
    final expiring = _otpRemaining <= 5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '动态验证码',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.8,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${config.algorithm.shortName} · ${config.digits} 位',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Divider(height: 0.5, color: theme.colorScheme.outline),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _groupedCode(_otpCode),
              key: const ValueKey('otp-code'),
              style: TextStyle(
                fontSize: 27,
                height: 1.1,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w500,
                fontFamily: 'Consolas',
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                '$_otpRemaining 秒',
                style: TextStyle(
                  fontSize: 12,
                  color: expiring
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: '复制验证码',
              icon: const Icon(Icons.copy_outlined, size: 16),
              color: theme.colorScheme.onSurfaceVariant,
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(_copyCode()),
            ),
            IconButton(
              key: const ValueKey('otp-remove'),
              tooltip: '删除这个验证码',
              icon: const Icon(Icons.delete_outline, size: 16),
              color: theme.colorScheme.onSurfaceVariant,
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(_removeOtp()),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(1),
          child: LinearProgressIndicator(
            value: _otpRemaining / config.period,
            minHeight: 2,
            backgroundColor: theme.colorScheme.outlineVariant,
            valueColor: AlwaysStoppedAnimation<Color>(
              // 平时用中性灰、最后一刻才变红：两种红（品牌砖红与「要过期了」的红）
              // 摆在一起，变色就失去意义了。
              expiring
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (config.label.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            config.label,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
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

/// 条目菜单里的动词。桌面右键与安卓长按共用同一份。
enum _EntryAction {
  copyPassword,
  copyUsername,
  copyUrl,
  edit,
  moveToGroup,
  delete,
}

/// 分组条上的动词。与条目菜单同一套手势，只是对象不同。
enum _GroupAction { rename, delete }

/// 选分组对话框。返回值：0 = 未分组，1..n = 第 n 个分组，`null` = 取消。
///
/// 用索引而不是组对象：`null` 已经留给「取消」了，而「未分组」本身也是一个
/// 合法选择——这两个语义必须能分开，否则用户点了「未分组」会被当成没点。
Future<int?> showGroupPicker(
  BuildContext context,
  VaultController vault,
  KdbxGroup? current,
) {
  final groups = vault.groups;
  return showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('放进哪个分组', style: TextStyle(fontSize: 15)),
      children: [
        _groupOption(ctx, 0, ungroupedLabel, current == null),
        for (var i = 0; i < groups.length; i++)
          _groupOption(
            ctx,
            i + 1,
            groups[i].name,
            current?.uuid == groups[i].uuid,
            count: groups[i].allEntries.length,
          ),
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 14),
            child: Text(
              '还没有分组。回列表页点右上角的文件夹图标建一个。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    ),
  );
}

Widget _groupOption(
  BuildContext ctx,
  int value,
  String label,
  bool selected, {
  int? count,
}) {
  final theme = Theme.of(ctx);
  return SimpleDialogOption(
    onPressed: () => Navigator.of(ctx).pop(value),
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
    child: Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
        if (count != null && count > 0) ...[
          Text(
            '$count 条',
            style: TextStyle(fontSize: 11.5, color: theme.hintColor),
          ),
          const SizedBox(width: 8),
        ],
        if (selected)
          Icon(Icons.check, size: 15, color: theme.colorScheme.primary),
      ],
    ),
  );
}
