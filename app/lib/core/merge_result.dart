/// 一次合并的结果，供界面告示「这次同步到底动了几条」。
///
/// 放在独立文件里（而不是塞进 [VaultController] 旁边）：同步协议层要用它，
/// 而协议层必须能在没有 Flutter 的环境里跑（命令行对端、测试夹具）。
class MergeResult {
  const MergeResult({
    required this.before,
    required this.after,
    required this.added,
    required this.removed,
    this.adopted = false,
  });

  /// 合并前本地的条目数。
  final int before;

  /// 合并后本地的条目数。
  final int after;

  /// 合并带来的新增条数。
  final int added;

  /// 合并带走的（墓碑生效）条数。
  final int removed;

  /// 这次不是「合并」而是「整库接管」：本地本来是空的，对端是另一个库
  /// （根分组 UUID 不同），于是把对端整库接下来。新设备第一次同步走的就是这条路。
  final bool adopted;

  bool get changed => added > 0 || removed > 0;

  String get summary {
    if (adopted) return '已接管对端的库（$after 条）';
    if (!changed) return '两边已经一致（$after 条）';
    final parts = <String>[];
    if (added > 0) parts.add('新增 $added');
    if (removed > 0) parts.add('移除 $removed');
    return '${parts.join(' · ')}，现在 $after 条';
  }

  @override
  String toString() =>
      'MergeResult(before: $before, after: $after, added: $added, '
      'removed: $removed, adopted: $adopted)';
}
