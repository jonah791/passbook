import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kpasslib/kpasslib.dart';

/// 封装 KDBX 库的打开/新建/保存与条目操作。
/// 只做本地文件读写，没有任何网络行为。
class VaultController extends ChangeNotifier {
  KdbxDatabase? _db;
  String? _filePath;

  bool get isOpen => _db != null;
  String? get filePath => _filePath;
  KdbxGroup? get root => _db?.root;

  List<KdbxEntry> get allEntries => _db?.root.allEntries ?? <KdbxEntry>[];

  KdbxGroup get rootGroup {
    final group = _db?.root;
    if (group == null) {
      throw StateError('数据库未打开');
    }
    return group;
  }

  Future<void> createNew(String path, String password) async {
    final credentials = KdbxCredentials(
      password: ProtectedData.fromString(password),
    );
    final db = KdbxDatabase.create(credentials: credentials, name: 'Passbook');
    final defaultGroup = db.createGroup(parent: db.root, name: '默认分组');
    _db = db;
    _filePath = path;
    // 新建库里放一个示例条目，空库打开时界面不至于全白。
    final entry = db.createEntry(parent: defaultGroup);
    entry.fields.addAll({
      'Title': KdbxTextField.fromText(text: '示例条目'),
      'UserName': KdbxTextField.fromText(text: 'user@example.com'),
      'Password': KdbxTextField.fromText(
        text: 'change-me',
        protected: true,
      ),
      'URL': KdbxTextField.fromText(text: ''),
      'Notes': KdbxTextField.fromText(text: '这是示例，可以修改或删除。'),
    });
    await save();
    notifyListeners();
  }

  Future<void> open(String path, String password) async {
    final bytes = await File(path).readAsBytes();
    final credentials = KdbxCredentials(
      password: ProtectedData.fromString(password),
    );
    final db = await KdbxDatabase.fromBytes(data: bytes, credentials: credentials);
    _db = db;
    _filePath = path;
    notifyListeners();
  }

  Future<void> save() async {
    final db = _db;
    final path = _filePath;
    if (db == null || path == null) return;
    final data = await db.save();
    final temp = File('$path.tmp');
    await temp.writeAsBytes(data, flush: true);
    await temp.rename(path);
  }

  KdbxGroup addGroup(KdbxGroup parent, String name) {
    final db = _db!;
    final group = db.createGroup(parent: parent, name: name);
    notifyListeners();
    return group;
  }

  KdbxEntry addEntry(KdbxGroup parent, {String title = '新条目'}) {
    final db = _db!;
    final entry = db.createEntry(parent: parent);
    entry.fields.addAll({
      'Title': KdbxTextField.fromText(text: title),
      'UserName': KdbxTextField.fromText(text: ''),
      'Password': KdbxTextField.fromText(text: '', protected: true),
      'URL': KdbxTextField.fromText(text: ''),
      'Notes': KdbxTextField.fromText(text: ''),
    });
    notifyListeners();
    return entry;
  }

  void updateEntry(KdbxEntry entry, Map<String, String> values) {
    for (final item in values.entries) {
      final protected = item.key == 'Password';
      entry.fields[item.key] = KdbxTextField.fromText(
        text: item.value,
        protected: protected,
      );
    }
    entry.times.touch();
    notifyListeners();
  }

  void deleteEntry(KdbxEntry entry) {
    final parent = entry.parent;
    if (parent is KdbxGroup) {
      parent.entries.remove(entry);
      notifyListeners();
    }
  }

  String fieldOf(KdbxEntry entry, String key) => entry.fields[key]?.text ?? '';

  void close() {
    _db = null;
    _filePath = null;
    notifyListeners();
  }
}
