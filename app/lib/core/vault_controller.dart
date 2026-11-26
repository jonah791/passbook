import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kpasslib/kpasslib.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'merge_result.dart';
import 'vault_bridge.dart';

export 'merge_result.dart';
export 'vault_bridge.dart';

/// 封装 KDBX 库的打开/新建/保存与条目操作。
/// 只做本地文件读写，没有任何网络行为。
class VaultController extends ChangeNotifier implements VaultBridge {
  static const _prefsKey = 'last_vault_path';

  KdbxDatabase? _db;
  String? _filePath;
  String? _lastError;

  /// 本次解锁期间的主密码，只活在内存里、锁定时丢弃。
  /// 同步要解密对端传回的库，没有它就只能在每次同步时再问一遍密码。
  String? _sessionPassword;

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

  /// 可能的库目录，按优先级：文档目录（方便同步到网盘）→ 应用数据目录。
  Future<List<String>> _candidateDirs() async {
    final dirs = <String>[];
    for (final getter in [
      getApplicationDocumentsDirectory,
      getApplicationSupportDirectory,
    ]) {
      try {
        dirs.add((await getter()).path);
      } catch (_) {
        // 拿不到这个目录就当它不存在，试下一个。
      }
    }
    return dirs;
  }

  /// 读上次打开的库路径（没有则 null）。
  ///
  /// 记住的路径只是**锚点**，不是真相：偏好项可能没写进去、库可能被挪走。
  /// 锚点失效时回退到「按默认位置找现成的库」——不能让用户因为一个偏好项
  /// 丢了就以为库没了、被迫重新建一个空库（那可是把密码本弄丢的观感）。
  Future<String?> readLastPath() async {
    final prefs = await SharedPreferences.getInstance();
    final remembered = prefs.getString(_prefsKey);
    if (remembered != null &&
        remembered.isNotEmpty &&
        await File(remembered).exists()) {
      return remembered;
    }

    for (final dir in await _candidateDirs()) {
      final candidate = '$dir${Platform.pathSeparator}passbook.kdbx';
      if (await File(candidate).exists()) {
        await _rememberPath(candidate);
        return candidate;
      }
    }
    return null;
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
    final picked = await pickWritable(await _candidateDirs());
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
      _sessionPassword = password;
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
      _sessionPassword = password;
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
    final db = _db;
    if (db == null) return;
    // 必须走 `move(target: null)`，它会写墓碑（deletedObjects）——同步才认得出
    // 「这条被删了」，否则合并时原样复活。
    // 不能用 `remove()`：那个会挪进回收站（库在没有回收站时会顺手建一个），
    // 条目仍在库里，对端合并后照样看得见。
    db.move(item: entry);
    notifyListeners();
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
    _sessionPassword = null; // 锁上就把钥匙丢了，不留内存副本
    notifyListeners();
  }

  /// 导出当前库的密文，用于同步。
  /// **线上永远只走这个**——链路是局域网的，但内容始终是 KDBX 密文。
  @override
  Future<Uint8List> exportBytes() async {
    final db = _db;
    if (db == null) throw StateError('库没打开');
    return Uint8List.fromList(await db.save());
  }

  /// 与对端库合并（对端传过来的是密文，这里用本次会话的主密码解开）。
  ///
  /// 用库自带的 `KdbxDatabase.merge`：它是 2P-set + 墓碑的正确实现，
  /// 覆盖「对端新增 / 本地新增 / 两边都改（按修改时间）」以及删除，
  /// 自己手写一份 CRDT 只会把删除传播写错。
  @override
  Future<MergeResult> mergeRemote(Uint8List remoteBytes) async {
    final db = _db;
    final password = _sessionPassword;
    if (db == null || password == null) throw StateError('库没打开');
    final remote = await KdbxDatabase.fromBytes(
      data: remoteBytes,
      credentials: KdbxCredentials(
        password: ProtectedData.fromString(password),
      ),
    );

    // 对端根本是**另一个库**（根分组 uuid 不同）时只有一条路是对的：
    // 本地还一条都没记 ⇒ 把对端整库接下来（新设备第一次同步就是这样）；
    // 本地有内容 ⇒ 拒绝，并且说清楚——绝不能悄悄拿对端把本地顶掉。
    if (remote.root.uuid != db.root.uuid) {
      final localCount = db.root.allEntries.length;
      if (localCount == 0) {
        _db = remote;
        _dirty = true;
        await flushNow();
        notifyListeners();
        return MergeResult(
          before: 0,
          after: remote.root.allEntries.length,
          added: remote.root.allEntries.length,
          removed: 0,
          adopted: true,
        );
      }
      throw StateError(
        '两边的库不是同一个（根分组 UUID 不同）：本地 $localCount 条，'
        '对端 ${remote.root.allEntries.length} 条。'
        '本机这条库已经有内容，不能用对端的库顶掉——'
        '先在空库的那台设备上连过来接管，之后再改就没关系了。',
      );
    }

    final before = _idsOf(db);
    db.merge(remote);
    final after = _idsOf(db);

    _dirty = true;
    await flushNow();
    notifyListeners();
    return MergeResult(
      before: before.length,
      after: after.length,
      added: after.difference(before).length,
      removed: before.difference(after).length,
    );
  }

  /// 用 [KdbxUuid] 本身做键，**不要 `toString()`**：它没重写 toString，
  /// 每个条目都会返回 "Instance of 'KdbxUuid'"，一套 Set 把所有条目折成一条。
  /// （它自带正确的 == / hashCode，拿对象当键是安全的。）
  static Set<KdbxUuid> _idsOf(KdbxDatabase db) => {
    for (final e in db.root.allEntries) e.uuid,
  };
}
