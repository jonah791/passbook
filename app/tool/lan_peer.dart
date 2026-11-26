// 命令行对端：用同一份同步协议（lib/core/sync_lan.dart）跑一个没有界面的库，
// 用来做**跨进程、跨设备**的联调——例如「Windows 端起服务端，Android 端去拉」。
//
// 为什么需要它：进程内的单元测试只能证明协议自洽，证明不了
// 「两台设备、两条网络栈、两个 OS 之间真能对上」。这个 CLI 就是那条对端的腿：
// 它不依赖 Flutter，所以能直接 `dart run` 起来。
//
// 用法：
//   dart run tool/lan_peer.dart create --vault a.kdbx --password pw --title "来自 Windows"
//   dart run tool/lan_peer.dart dump   --vault a.kdbx --password pw
//   dart run tool/lan_peer.dart serve  --vault a.kdbx --password pw --port 8123 --code 123456
//   dart run tool/lan_peer.dart pull   --vault b.kdbx --password pw --host 192.168.1.7 --port 8123 --code 123456
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:kpasslib/kpasslib.dart';
import 'package:passbook/core/merge_result.dart';
import 'package:passbook/core/sync_lan.dart';
import 'package:passbook/core/vault_bridge.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(_usage);
    exit(64);
  }
  final command = args.first;
  final opts = _parse(args.skip(1).toList());
  final vaultPath = opts['vault'];
  final password = opts['password'];
  if (vaultPath == null || password == null) {
    stderr.writeln('缺 --vault 或 --password\n\n$_usage');
    exit(64);
  }

  switch (command) {
    case 'create':
      final vault = _FileVault(vaultPath, password);
      await vault.create(title: opts['title'] ?? '新建条目', notes: opts['notes']);
      stdout.writeln('CREATED $vaultPath');
      await _dump(vault);
    case 'add':
      final vault = _FileVault(vaultPath, password);
      await vault.add(title: opts['title'] ?? '新增条目', notes: opts['notes']);
      stdout.writeln('ADDED $vaultPath');
      await _dump(vault);
    case 'dump':
      await _dump(_FileVault(vaultPath, password));
    case 'serve':
      await _serve(
        _FileVault(vaultPath, password),
        port: int.parse(opts['port'] ?? '8123'),
        code: opts['code'],
        timeout: Duration(seconds: int.parse(opts['timeout'] ?? '180')),
      );
    case 'pull':
      final host = opts['host'];
      final port = opts['port'];
      final code = opts['code'];
      if (host == null || port == null || code == null) {
        stderr.writeln('pull 需要 --host --port --code\n\n$_usage');
        exit(64);
      }
      await _pull(
        _FileVault(vaultPath, password),
        host: host,
        port: int.parse(port),
        code: code,
      );
    default:
      stderr.writeln('不认识的命令：$command\n\n$_usage');
      exit(64);
  }
}

const _usage = '''
命令：
  create --vault <路径> --password <主密码> [--title <标题>] [--notes <说明>]
  add    --vault <路径> --password <主密码> [--title <标题>] [--notes <说明>]
  dump   --vault <路径> --password <主密码>
  serve  --vault <路径> --password <主密码> [--port 8123] [--code 123456] [--timeout 180]
  pull   --vault <路径> --password <主密码> --host <地址> --port <端口> --code <配对码>''';

Map<String, String> _parse(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) continue;
    final key = a.substring(2);
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      out[key] = args[++i];
    } else {
      out[key] = 'true';
    }
  }
  return out;
}

Future<void> _serve(
  _FileVault vault, {
  required int port,
  String? code,
  required Duration timeout,
}) async {
  final sync = LanSync(vault);
  final merged = Completer<MergeResult>();
  sync.onMerged = (result) {
    if (!merged.isCompleted) merged.complete(result);
  };
  final actualCode = await sync.start(port: port, code: code);
  final ips = await LanSync.localIPv4();
  stdout.writeln('READY port=${sync.port} code=$actualCode ips=${ips.join(",")}');
  await stdout.flush();

  try {
    final result = await merged.future.timeout(timeout);
    stdout.writeln('MERGED added=${result.added} removed=${result.removed} '
        'after=${result.after}');
  } on TimeoutException {
    stderr.writeln('TIMEOUT 等了 ${timeout.inSeconds} 秒没有对端来同步');
    await sync.stop();
    exit(3);
  }
  // 让 POST 的响应先写完，再收摊。
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await sync.stop();
  await _dump(vault);
}

Future<void> _pull(
  _FileVault vault, {
  required String host,
  required int port,
  required String code,
}) async {
  final sync = LanSync(vault);
  final result = await sync.pullFrom(host: host, port: port, code: code);
  stdout.writeln('PULLED added=${result.added} removed=${result.removed} '
      'after=${result.after}');
  await _dump(vault);
}

Future<void> _dump(_FileVault vault) async {
  final titles = await vault.titles();
  for (final t in titles) {
    stdout.writeln('ENTRY $t');
  }
  stdout.writeln('COUNT ${titles.length}');
  await stdout.flush();
}

/// 把 KDBX 文件包成 [VaultBridge]——协议只看密文，这里也只吐密文。
class _FileVault implements VaultBridge {
  _FileVault(this.path, this.password);

  final String path;
  final String password;

  Future<KdbxDatabase> _load() async {
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('库文件不存在：$path');
    }
    return KdbxDatabase.fromBytes(
      data: await file.readAsBytes(),
      credentials: KdbxCredentials(
        password: ProtectedData.fromString(password),
      ),
    );
  }

  Future<void> _store(KdbxDatabase db) async {
    await File(path).writeAsBytes(await db.save(), flush: true);
  }

  Future<void> create({required String title, String? notes}) async {
    final db = KdbxDatabase.create(
      credentials: KdbxCredentials(
        password: ProtectedData.fromString(password),
      ),
      name: 'Passbook',
    );
    db.createGroup(parent: db.root, name: '默认分组');
    final entry = db.createEntry(parent: db.root);
    entry.fields.addAll({
      'Title': KdbxTextField.fromText(text: title),
      'Notes': KdbxTextField.fromText(text: notes ?? ''),
    });
    await _store(db);
  }

  /// 往已有库里加一条（用来制造「两端各自新增」的同步场景）。
  Future<void> add({required String title, String? notes}) async {
    final db = await _load();
    final entry = db.createEntry(parent: db.root);
    entry.fields.addAll({
      'Title': KdbxTextField.fromText(text: title),
      'Notes': KdbxTextField.fromText(text: notes ?? ''),
    });
    await _store(db);
  }

  @override
  Future<Uint8List> exportBytes() async {
    final db = await _load();
    return Uint8List.fromList(await db.save());
  }

  @override
  Future<MergeResult> mergeRemote(Uint8List remoteBytes) async {
    final db = await _load();
    final remote = await KdbxDatabase.fromBytes(
      data: remoteBytes,
      credentials: KdbxCredentials(
        password: ProtectedData.fromString(password),
      ),
    );
    // 与 VaultController 同一条规则：不同库 + 本地空 ⇒ 接管；不同库 + 本地有内容 ⇒ 拒绝。
    if (remote.root.uuid != db.root.uuid) {
      final localCount = db.root.allEntries.length;
      if (localCount == 0) {
        await _store(remote);
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
        '对端 ${remote.root.allEntries.length} 条',
      );
    }
    final before = _idsOf(db);
    db.merge(remote);
    final after = _idsOf(db);
    await _store(db);
    return MergeResult(
      before: before.length,
      after: after.length,
      added: after.difference(before).length,
      removed: before.difference(after).length,
    );
  }

  Future<List<String>> titles() async {
    final db = await _load();
    return [
      for (final e in db.root.allEntries) e.fields['Title']?.text ?? '(无标题)',
    ];
  }

  /// 用 uuid 对象做键（它没重写 toString，转字符串会把所有条目折成一条）。
  static Set<KdbxUuid> _idsOf(KdbxDatabase db) => {
    for (final e in db.root.allEntries) e.uuid,
  };
}
