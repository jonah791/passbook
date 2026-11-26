/// 版本比较：只服务「有没有新版」这一件事。
///
/// 为什么不引 `pub_semver`：这条判断要能在一屏里读清、在测试里一句话写死；
/// 而本应用只发 `major.minor.patch` 三档，预发布版按 semver §11 排在正式版之前。
/// 引一个通用库会把「我需要判什么」埋进几千行规格里。
class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch, [this.pre]);

  final int major;
  final int minor;
  final int patch;

  /// 预发布尾巴（`1.2.3-beta.1` 的 `beta.1`）。正式版为 null。
  final String? pre;

  static final RegExp _pattern = RegExp(
    r'^[vV]?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.\-]+))?(?:\+[0-9A-Za-z.\-]+)?$',
  );

  /// 解析 `v1.2.3` / `1.2.3` / `1.2.3-beta.1` / `1.2.3+build.7`。
  ///
  /// 解析不出返回 null，**不**退化成 `0.0.0`——退化会让「最新版」静默变成
  /// 「你没有新版」，而正确行为是把它当成一次失败的检查报出来。
  static SemVer? tryParse(String? raw) {
    if (raw == null) return null;
    final match = _pattern.firstMatch(raw.trim());
    if (match == null) return null;
    return SemVer(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      match[4],
    );
  }

  bool get isPrerelease => pre != null;

  /// 是否比 [other] 新。
  bool isNewerThan(SemVer other) => compareTo(other) > 0;

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    // 同号：正式版 > 预发布版（semver §11.3）
    if (pre == null && other.pre == null) return 0;
    if (pre == null) return 1;
    if (other.pre == null) return -1;
    return _comparePrerelease(pre!, other.pre!);
  }

  static int _comparePrerelease(String a, String b) {
    final pa = a.split('.');
    final pb = b.split('.');
    for (var i = 0; i < pa.length && i < pb.length; i++) {
      final x = int.tryParse(pa[i]);
      final y = int.tryParse(pb[i]);
      if (x != null && y != null) {
        if (x != y) return x.compareTo(y);
      } else if (x != null) {
        return -1; // 纯数字标识符优先级低于字母数字
      } else if (y != null) {
        return 1;
      } else {
        final c = pa[i].compareTo(pb[i]);
        if (c != 0) return c;
      }
    }
    // 前缀相同时，标识符多的一方更大（1.0.0-alpha < 1.0.0-alpha.1）
    return pa.length.compareTo(pb.length);
  }

  @override
  bool operator ==(Object other) =>
      other is SemVer &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.pre == pre;

  @override
  int get hashCode => Object.hash(major, minor, patch, pre);

  @override
  String toString() => pre == null ? '$major.$minor.$patch' : '$major.$minor.$patch-$pre';
}
