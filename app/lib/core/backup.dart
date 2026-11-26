import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import 'vault_controller.dart';

/// 备份与恢复。
///
/// 只以**密文**为单位：备份文件就是 KDBX 字节，用主密码才打得开。
/// 不额外再包一层加密——包了只会让人以为那需要另一把钥匙。
///
/// 恢复有两条路，语义不同，不能互相替代：
///   * 合并（[mergeFrom]）：只增不减。**误删的条目救不回来**——备份里的条目
///     还活着，但本地那条删除记录比备份新，合并会尊重较新的那个。
///   * 替换（[replaceFrom]）：真的回到备份那一刻，备份之后新增的条目会消失。
///
/// 两条都建立在 [VaultController] 已有的密文接口上，不另写一套合并逻辑：
/// 删除墓碑、冲突按修改时间取胜这些细节只该有一份实现，否则迟早走样。
class BackupService {
  BackupService(this.vault, {Directory? directory}) : _directory = directory;

  final VaultController vault;

  /// 备份目录的覆盖口。留空就用应用文档目录下的 `backups/`。
  /// 存在理由：测试要把它关进临时目录，不该反过来去桩掉 path_provider 的平台通道。
  final Directory? _directory;

  /// 历史备份目录。
  Future<Directory> historyDir() async {
    final dir =
        _directory ??
        Directory(
          '${(await getApplicationDocumentsDirectory()).path}'
          '${Platform.pathSeparator}backups',
        );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 建议的文件名：`passbook-20261126-1633.kdbx`。
  static String suggestedName(DateTime now) =>
      'passbook-${DateFormat('yyyyMMdd-HHmm').format(now)}.kdbx';

  /// 把当前库的密文写到 [target]，返回写入的字节数。
  ///
  /// 先写 `.part` 再改名：备份写到一半断电，不该在磁盘上留下一个
  /// 看起来正常、实际打不开的 `.kdbx`——那比没有备份更坏。
  Future<int> exportTo(File target) async {
    final bytes = await vault.exportBytes();
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) {
      await target.delete();
    }
    await tmp.rename(target.path);
    return bytes.length;
  }

  /// 导出一份带时间戳的历史备份，返回该文件。
  Future<File> exportHistory({DateTime? now}) async {
    final dir = await historyDir();
    final f = File(
      '${dir.path}${Platform.pathSeparator}'
      '${suggestedName(now ?? DateTime.now())}',
    );
    await exportTo(f);
    return f;
  }

  /// 从备份文件**合并**进当前库，返回这次合并动了什么。
  Future<MergeResult> mergeFrom(File source) async {
    final bytes = await source.readAsBytes();
    return vault.mergeRemote(bytes);
  }

  /// 用备份文件**整体替换**当前库，返回替换前自动留下的那份现状备份。
  ///
  /// 「恢复错了」没有第二次机会，所以替换前先把手上的库导一份
  /// `before-restore-*.kdbx`。返回它，让界面能告诉用户后悔药在哪。
  Future<File> replaceFrom(File source) async {
    final bytes = await source.readAsBytes();
    final dir = await historyDir();
    final stamp = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
    final safety = File(
      '${dir.path}${Platform.pathSeparator}before-restore-$stamp.kdbx',
    );
    await exportTo(safety);
    await vault.replaceWith(bytes);
    return safety;
  }

  /// 历史备份列表，最新的在前（文件名里带 `<年><月><日>-<时><分>`，字典序即时间序）。
  Future<List<File>> listHistory() async {
    final dir = await historyDir();
    final files = await dir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.kdbx'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  /// 删除一份历史备份。只让删 `backups/` 里的 `.kdbx`，别的一概不碰。
  Future<void> deleteHistory(File file) async {
    final dir = await historyDir();
    final abs = file.absolute.path;
    if (!abs.startsWith(dir.absolute.path)) {
      throw ArgumentError('只允许删除备份目录里的文件');
    }
    if (!abs.toLowerCase().endsWith('.kdbx')) {
      throw ArgumentError('只允许删除 .kdbx 文件');
    }
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// 给用户看的字节数。
  static String humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 给用户看的时间：`11-26 16:33`。
  static String humanTime(File file) {
    final m = RegExp(r'(\d{8})-(\d{4})').firstMatch(file.path);
    if (m != null) {
      final d = m.group(1)!;
      final t = m.group(2)!;
      return '${d.substring(4, 6)}-${d.substring(6, 8)} '
          '${t.substring(0, 2)}:${t.substring(2, 4)}';
    }
    return file.lastModifiedSync().toString().substring(0, 16);
  }
}
