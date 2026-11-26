import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kpasslib/kpasslib.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 封装 KDBX 库的打开/新建/保存与条目操作。
/// 只做本地文件读写，没有任何网络行为。
class VaultController extends ChangeNotifier {
  static const _prefsKey = 'last_vault_path';

  KdbxDatabase? _db;
  String? _filePath;
  String? _lastError;

  Timer? _saveTimer;
  bool _dirty = false;
  Future<void>? _inflight;

  bool get isOpen => _db != null;
  String? get filePath => _filePath;
  String? get lastError => _lastError;
  KdbxGroup? get root => _db?.root;

  List<KdbxEntry> get allEntries {
    final entries = _db?.root.allEntries ?? <KdbxEntry>[];
    // 新的在前：便签应用的心智是「最近记的在上面」。
    entries.sort(
      (a, b) =>
          b.times.creation.timeOrZero.compareTo(a.times.creation.timeOrZero),
    );
    return entries;
  }

  KdbxGroup get rootGroup {
    final group = _db?.root;
    if (group == null) {
      throw StateError('数据库未打开');
    }
    return group;
  }

  /// 读上次打开的库路径（没有则 null）。
  Future<String?> readLastPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_prefsKey);
    if (path == null || path.isEmpty) return null;
    if (!await File(path).exists()) return null;
    return path;
  }

  Future<void> _rememberPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, path);
  }

  /// 默认库位置：文档目录/passbook.kdbx（用户不需要选文件）。
  Future<String> defaultVaultPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}${Platform.pathSeparator}passbook.kdbx';
  }

  /// 首次使用：在默认位置创建库。返回是否成功。
  Future<bool> createDefault(String password) async {
    final path = await defaultVaultPath();
    return createAt(path, password);
  }

  Future<bool> createAt(String path, String password) async {
    _lastError = null;
    try {
      final credentials = KdbxCredentials(
        password: ProtectedData.fromString(password),
      );
      final db = KdbxDatabase.create(
        credentials: credentials,
        name: 'Passbook',
      );
      db.createGroup(parent: db.root, name: '默认分组');
      _db = db;
      _filePath = path;
      await save();
      await _rememberPath(path);
      notifyListeners();
      return true;
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> open(String path, String password) async {
    _lastError = null;
    try {
      final bytes = await File(path).readAsBytes();
      final credentials = KdbxCredentials(
        password: ProtectedData.fromString(password),
      );
      final db = await KdbxDatabase.fromBytes(
        data: bytes,
        credentials: credentials,
      );
      _db = db;
      _filePath = path;
      await _rememberPath(path);
      notifyListeners();
      return true;
    } catch (e) {
      _lastError = '主密码不对，或文件不是 KDBX 库。';
      notifyListeners();
      return false;
    }
  }

  Future<void> save() async {
    final db = _db;
    final path = _filePath;
    if (db == null || path == null) return;
    final data = await db.save();
    final temp = File('$path.tmp');
    await temp.writeAsBytes(data, flush: true);
    if (await File(path).exists()) {
      await File(path).delete();
    }
    await temp.rename(path);
  }

  /// 标记「内存里有改动，稍后落盘」：800ms 后自动写，连续输入只写一次。
  ///
  /// 与页面自建定时器的区别：**页面被销毁（快速返回）或自动锁定触发时，
  /// 挂起的改动要有统一的地方去 flush**，否则最后几个字会被静默丢掉。
  void scheduleSave() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(flushNow());
    });
  }

  /// 立即落盘（有未保存改动才写）。并发调用会等同一份写入，不会写两遍。
  Future<void> flushNow() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final pending = _inflight;
    if (pending != null) await pending;
    if (!_dirty) return;
    _dirty = false;
    final future = save();
    _inflight = future;
    try {
      await future;
    } catch (e) {
      // 写失败不能静默：保留脏标记让下次重试，并把原因交给界面。
      _dirty = true;
      _lastError = '保存失败：$e';
      notifyListeners();
    } finally {
      if (identical(_inflight, future)) _inflight = null;
    }
  }

  KdbxEntry addEntry({KdbxGroup? parent, String title = ''}) {
    final db = _db!;
    final group = parent ?? db.root;
    final entry = db.createEntry(parent: group);
    entry.fields.addAll({
      'Title': KdbxTextField.fromText(text: title),
      'Notes': KdbxTextField.fromText(text: ''),
    });
    notifyListeners();
    return entry;
  }

  void updateField(KdbxEntry entry, String key, String value) {
    entry.fields[key] = KdbxTextField.fromText(
      text: value,
      protected: key == 'Password',
    );
    entry.times.touch();
  }

  void deleteEntry(KdbxEntry entry) {
    final parent = entry.parent;
    if (parent is KdbxGroup) {
      parent.entries.remove(entry);
      notifyListeners();
    }
  }

  String fieldOf(KdbxEntry entry, String key) => entry.fields[key]?.text ?? '';

  bool hasPassword(KdbxEntry entry) => fieldOf(entry, 'Password').isNotEmpty;

  /// 列表预览：优先正文，其次用户名。
  String previewOf(KdbxEntry entry) {
    final notes = fieldOf(
      entry,
      'Notes',
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (notes.isNotEmpty) return notes;
    final user = fieldOf(entry, 'UserName');
    if (user.isNotEmpty) return user;
    return '';
  }

  void close() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_dirty) {
      // 调用方应当在关闭前 await flushNow()。喊出来，别静默丢。
      debugPrint('VaultController.close(): 存在未落盘的改动，已丢弃');
    }
    _dirty = false;
    _db = null;
    _filePath = null;
    notifyListeners();
  }
}
