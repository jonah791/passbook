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

  /// 默认库位置：优先用户可见的文档目录（方便丢进网盘同步、方便在手机上打开），
  /// 写不了再退到应用数据目录。
  ///
  /// 「能不能写」必须**实测**：这台机器开着 Windows 受控文件夹访问（CFA），
  /// 文档目录读得到、列得出，写进去却报「系统找不到指定的文件」。
  /// 只看目录存不存在会误判成可用，于是用户第一次建库就撞墙。
  Future<String> defaultVaultPath() async {
    final candidates = <String>[];
    for (final getter in [
      getApplicationDocumentsDirectory,
      getApplicationSupportDirectory,
    ]) {
      try {
        candidates.add((await getter()).path);
      } catch (_) {
        // 拿不到这个目录就当它不存在，试下一个。
      }
    }
    final picked = await pickWritable(candidates);
    if (picked == null) {
      throw StateError('没有可写目录：文档与应用数据目录都写不进去');
    }
    return picked;
  }

  /// 在候选目录里挑第一个**真的能写**的，返回库文件完整路径；都不行返回 null。
  ///
  /// 必须是实测而不是「目录存在就算数」：见 [defaultVaultPath] 的注释。
  static Future<String?> pickWritable(
    List<String> candidates, {
    String fileName = 'passbook.kdbx',
  }) async {
    final sep = Platform.pathSeparator;
    for (final dirPath in candidates) {
      final probe = File('$dirPath${sep}passbook-write-probe.tmp');
      try {
        await probe.parent.create(recursive: true);
        await probe.writeAsBytes(const [0], flush: true);
        await probe.delete();
        return '$dirPath$sep$fileName';
      } catch (_) {
        continue;
      }
    }
    return null;
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
      _lastError = _humanizeWrite(e);
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
      final s = e.toString();
      final missing =
          s.contains('PathNotFound') ||
          s.contains('系统找不到') ||
          s.contains('errno = 2');
      _lastError = missing
          ? '库文件不在那个位置了（可能被移动、删除，或被系统拦住）。'
          : '主密码不对，或文件不是 KDBX 库。';
      notifyListeners();
      return false;
    }
  }

  /// 系统错误说人话。把 `PathNotFoundException ... errno = 2` 原样甩给用户
  /// 等于没说——Windows 被「受控文件夹访问」拦住时报的就是「找不到文件」。
  static String _humanizeWrite(Object error) {
    final s = error.toString();
    if (s.contains('errno = 2') ||
        s.contains('PathNotFound') ||
        s.contains('系统找不到')) {
      return '写不进去：这个目录被系统拦住了。\n'
          '多半是 Windows「受控文件夹访问」开着——在 安全中心 → 病毒和威胁防护 → '
          '受控文件夹访问 里放行即可。';
    }
    if (s.contains('errno = 5') || s.contains('拒绝访问') || s.contains('denied')) {
      return '写不进去：没有这个目录的写权限。';
    }
    return '保存失败：$s';
  }

  Future<void> save() async {
    final db = _db;
    final path = _filePath;
    if (db == null || path == null) return;
    final data = await db.save();
    final temp = File('$path.tmp');
    // 目录可能在运行期间被删掉或挪走；写之前确保它在，否则报的错会误导人。
    await temp.parent.create(recursive: true);
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
