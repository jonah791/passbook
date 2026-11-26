import 'dart:math';

/// 随机密码生成。
///
/// 只用 [Random.secure()]：普通 `Random` 的输出可预测，拿来做密码等于没做。
/// 去掉 0/O/1/l/I 这类肉眼易混的字符——密码本里最常见的错误是抄错，不是被猜中。
class PasswordGenerator {
  static const lower = 'abcdefghijkmnopqrstuvwxyz'; // 去掉 l
  static const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; // 去掉 I O
  static const digits = '23456789'; // 去掉 0 1
  static const symbols = r'!@#$%^&*-_=+?';

  static const alphabet = '$lower$upper$digits$symbols';

  /// 默认长度。20 位含四类字符 ≈ 远超离线爆破成本，又不至于长到无法手抄。
  static const defaultLength = 20;

  /// 生成 [length] 位密码，四类字符各至少一个（不少站点有这条硬要求）。
  static String generate({int length = defaultLength, Random? random}) {
    assert(length >= 4, '至少要能放下四类字符各一个');
    final rng = random ?? Random.secure();
    final chars = <String>[
      for (final set in [lower, upper, digits, symbols])
        set[rng.nextInt(set.length)],
    ];
    while (chars.length < length) {
      chars.add(alphabet[rng.nextInt(alphabet.length)]);
    }
    chars.shuffle(rng);
    return chars.join();
  }
}
