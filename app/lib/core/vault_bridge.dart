import 'dart:typed_data';

import 'merge_result.dart';

/// 同步协议眼里的「库」：能交出密文、能吃掉对端密文并合并。
///
/// 为什么要有这层接口：协议逻辑（开端口、发请求、配对码）与「库怎么存」无关，
/// 拆开后同一份协议代码既可以跑在 Flutter 应用里（[VaultController]），
/// 也可以跑在命令行对端（`tool/lan_peer.dart`）里——跨进程联调靠的就是这个。
///
/// **接口只谈密文**：实现方交出的必须是 KDBX 字节，绝不能是解密后的条目。
abstract interface class VaultBridge {
  /// 导出当前库的密文（KDBX 字节）。
  Future<Uint8List> exportBytes();

  /// 用对端密文合并进本地库，返回这次合并动了什么。
  Future<MergeResult> mergeRemote(Uint8List remoteBytes);
}
