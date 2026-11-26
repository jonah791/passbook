import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// 动态验证码（TOTP，RFC 6238）。纯计算：没有网络、没有状态、不碰文件。
///
/// 判据来自标准本身：RFC 4226 的十条 HOTP 向量与 RFC 6238 的六条 TOTP 向量
/// 都进了单元测试。自己造一组「看起来对」的样本没有意义——算法里任何一处
/// 差半字节（大端序、动态截断的偏移、取模位数）都会让码完全错，而错码和
/// 对码长得一模一样，只有标准向量能分辨。
///
/// 密钥是**明文**的一部分：它进 KDBX 时按 KeePassXC 的约定存在 `otp` 字段里
/// 并置为受保护字段（见 [VaultController.updateField]），与密码同等看待。
class TotpAlgorithm {
  const TotpAlgorithm._(this.label);

  /// 写进 otpauth 链接里的名字（全大写，无连字符）。
  final String label;

  static const sha1 = TotpAlgorithm._('SHA1');
  static const sha256 = TotpAlgorithm._('SHA256');
  static const sha512 = TotpAlgorithm._('SHA512');

  static const values = [sha1, sha256, sha512];

  /// 认链接里的 `algorithm` 参数。缺省按 RFC 6238 是 SHA1。
  static TotpAlgorithm? fromName(String? name) {
    if (name == null || name.trim().isEmpty) return sha1;
    final normalized = name.toUpperCase().replaceAll('-', '');
    for (final algorithm in values) {
      if (algorithm.label == normalized) return algorithm;
    }
    return null;
  }

  crypto.Hash get hash => switch (label) {
    'SHA256' => crypto.sha256,
    'SHA512' => crypto.sha512,
    _ => crypto.sha1,
  };

  /// 三种摘要的短名，只用于界面显示。
  String get shortName => label.replaceFirst('SHA', 'SHA-');
}

const _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// Base32 解码（RFC 4648，不带填充也可以）。
///
/// 容忍空格、连字符与换行：Google 身份验证器导出来的密钥常被按四字符分组
/// 写成 `abcd efgh ijkl`，用户复制粘贴时会连空格一起带过来。
/// **不认识就返回 null，不猜**——把 `0`（零）当成 `O` 之类的「贴心纠错」
/// 会算出一个永远不对的码，而用户只会怀疑自己抄错了密钥。
Uint8List? base32Decode(String input) {
  final chars = StringBuffer();
  for (final rune in input.toUpperCase().runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '=' || ch == ' ' || ch == '-' || ch == '\t') continue;
    if (ch == '\n' || ch == '\r') continue;
    if (!_base32Alphabet.contains(ch)) return null;
    chars.write(ch);
  }
  final text = chars.toString();
  if (text.isEmpty) return null;

  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final ch in text.split('')) {
    buffer = ((buffer << 5) | _base32Alphabet.indexOf(ch)) & 0xFFFF;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
  }
  return Uint8List.fromList(out);
}

/// 10 的 [digits] 次方。写成循环而不是 `math.pow`：`pow` 返回 `num`，
/// 转回 `int` 多一次类型判断，而这里只需要一个整数。
int _pow10(int digits) {
  var result = 1;
  for (var i = 0; i < digits; i++) {
    result *= 10;
  }
  return result;
}

/// HOTP（RFC 4226）：给计数器和密钥，直接算码。TOTP 就是它的时间版本。
String hotp(
  Uint8List secret,
  int counter, {
  int digits = 6,
  TotpAlgorithm algorithm = TotpAlgorithm.sha1,
}) {
  // 计数器必须按 8 字节大端写进消息：写成小端会得到一组「稳定但错误」的码，
  // 而且每个计数器都对不上，很难从现象反推原因。
  final message = Uint8List(8);
  var remaining = counter;
  for (var i = 7; i >= 0; i--) {
    message[i] = remaining & 0xff;
    remaining >>= 8;
  }

  final mac = crypto.Hmac(algorithm.hash, secret).convert(message).bytes;

  // 动态截断：取摘要末字节的低四位当偏移，从那里读 4 字节、抹掉最高位，
  // 得到一个正的 31 位整数。这一步是 RFC 4226 §5.3 的全部内容。
  final offset = mac[mac.length - 1] & 0x0f;
  final binary =
      ((mac[offset] & 0x7f) << 24) |
      (mac[offset + 1] << 16) |
      (mac[offset + 2] << 8) |
      mac[offset + 3];

  return (binary % _pow10(digits)).toString().padLeft(digits, '0');
}

/// 一条动态验证码的全部参数。
class TotpConfig {
  const TotpConfig({
    required this.secret,
    this.digits = 6,
    this.period = 30,
    this.algorithm = TotpAlgorithm.sha1,
    this.issuer = '',
    this.account = '',
  });

  final Uint8List secret;
  final int digits;
  final int period;
  final TotpAlgorithm algorithm;
  final String issuer;
  final String account;

  /// 某一时刻落在第几个时间窗口。
  int counterAt(DateTime when) =>
      when.millisecondsSinceEpoch ~/ 1000 ~/ period;

  /// 某一时刻的验证码。
  String codeAt(DateTime when) =>
      hotp(secret, counterAt(when), digits: digits, algorithm: algorithm);

  /// 当前这个码还剩几秒（1 到 [period]）。界面用它画倒计时。
  ///
  /// 整除时返回 [period] 而不是 0：一个「还剩 0 秒」的码在界面上等于
  /// 已经过期，但它其实刚生效、还能用整整一个周期。
  int remainingAt(DateTime when) {
    final epochSeconds = when.millisecondsSinceEpoch ~/ 1000;
    final left = period - (epochSeconds % period);
    return left == 0 ? period : left;
  }

  /// 界面上的归属说明：`Issuer · 账号`，缺哪个就只显示另一个。
  String get label {
    final parts = [issuer, account].where((s) => s.trim().isNotEmpty);
    return parts.join(' · ');
  }
}

/// 解析结果。失败时带上说人话的原因——用户看到的不能只是「无效」。
class TotpParse {
  const TotpParse.ok(this.config) : error = null;
  const TotpParse.fail(this.error) : config = null;

  final TotpConfig? config;
  final String? error;

  bool get isOk => config != null;
}

/// 解析用户给的东西：otpauth 链接，或者裸的 Base32 密钥。
TotpParse parseTotp(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const TotpParse.fail('密钥是空的');

  // 用户常常把整段提示语一起粘过来（「密钥：otpauth://...」），
  // 从链接出现的位置开始读，比要求他手动删干净友善。
  final uriStart = text.toLowerCase().indexOf('otpauth://');
  if (uriStart >= 0) {
    return _parseUri(text.substring(uriStart).trim());
  }

  final secret = base32Decode(text);
  if (secret == null) {
    return const TotpParse.fail('密钥不是有效的 Base32：只允许字母 A-Z 与数字 2-7');
  }
  if (secret.length < 4) {
    return const TotpParse.fail('密钥太短了，不像是一个验证器密钥');
  }
  return TotpParse.ok(TotpConfig(secret: secret));
}

TotpParse _parseUri(String text) {
  // 链接里可能带着用户抄进来的尾巴（例如后面还有一句中文说明），
  // 按空白切一刀，只取第一段。
  final firstChunk = text.split(RegExp(r'\s')).first;

  final Uri uri;
  try {
    uri = Uri.parse(firstChunk);
  } catch (_) {
    return const TotpParse.fail('链接格式不对：不能解析成网址');
  }

  if (uri.scheme.toLowerCase() != 'otpauth') {
    return const TotpParse.fail('不是动态验证码链接');
  }
  final kind = uri.host.toLowerCase();
  if (kind != 'totp') {
    return TotpParse.fail(
      kind == 'hotp'
          ? '这是按次数计的验证码（HOTP），本应用只支持按时间计的（TOTP）'
          : '不支持这种验证码：$kind',
    );
  }

  final params = uri.queryParameters;
  final secret = base32Decode(params['secret'] ?? '');
  if (secret == null || secret.isEmpty) {
    return const TotpParse.fail('链接里没有可用的 secret 参数');
  }

  final digits = int.tryParse(params['digits'] ?? '') ?? 6;
  if (digits < 6 || digits > 8) {
    return const TotpParse.fail('位数只支持 6 到 8 位');
  }
  final period = int.tryParse(params['period'] ?? '') ?? 30;
  if (period < 1) {
    return const TotpParse.fail('时间周期必须大于 0 秒');
  }
  final algorithm = TotpAlgorithm.fromName(params['algorithm']);
  if (algorithm == null) {
    return TotpParse.fail('不支持的算法：${params['algorithm']}');
  }

  // 标签形如 `/Issuer:Account`，冒号前是发行方。查询参数里也常带一份
  // `issuer`，冲突时以参数为准（它不带编码歧义）。
  var label = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
  var issuer = params['issuer'] ?? '';
  var account = label;
  final colon = label.indexOf(':');
  if (colon >= 0) {
    final prefix = label.substring(0, colon).trim();
    account = label.substring(colon + 1).trim();
    if (issuer.trim().isEmpty) issuer = prefix;
  }

  return TotpParse.ok(
    TotpConfig(
      secret: secret,
      digits: digits,
      period: period,
      algorithm: algorithm,
      issuer: issuer.trim(),
      account: account.trim(),
    ),
  );
}
