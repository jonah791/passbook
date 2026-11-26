import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/totp.dart';

/// 动态验证码的判据全部来自标准原文，不用自造样本：
/// - RFC 4648 §10：Base32 的四组编码向量
/// - RFC 4226 附录 D：HOTP 的前十个计数器
/// - RFC 6238 附录 B：三种摘要各六个时间点
///
/// 为什么必须这样：算法里任何一处差半字节（大端序、动态截断偏移、取模位数），
/// 得到的都是一个「稳定的错码」。错码和正确的码长得一模一样，也没有任何
/// 本地现象能提示它错了——只有标准向量能分辨。
void main() {
  /// RFC 4226 / 6238 的共享密钥：ASCII 的 "12345678901234567890"。
  final rfcSecret = Uint8List.fromList(utf8.encode('12345678901234567890'));

  /// 上面那串的 Base32 写法（20 字节正好 32 个字符，无需填充）。
  const rfcSecretBase32 = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

  /// 以「从 Unix 纪元起多少秒」取码。
  String codeAtSeconds(TotpConfig config, int seconds) =>
      config.codeAt(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));

  group('Base32 解码', () {
    test('RFC 4648 §10 的四组向量', () {
      expect(utf8.decode(base32Decode('MZXW6===')!), 'foo');
      expect(utf8.decode(base32Decode('MZXW6YQ=')!), 'foob');
      expect(utf8.decode(base32Decode('MZXW6YTB')!), 'fooba');
      expect(utf8.decode(base32Decode('MZXW6YTBOI======')!), 'foobar');
    });

    test('容忍小写、空格、连字符与换行', () {
      // 身份验证器导出的密钥常被按四字符分组，复制粘贴会带上分隔符。
      expect(utf8.decode(base32Decode('mzxw 6ytb')!), 'fooba');
      expect(utf8.decode(base32Decode('MZXW-6YTB\n')!), 'fooba');
      expect(base32Decode(rfcSecretBase32), rfcSecret);
    });

    test('不认识的字符返回 null，而不是猜一个近似值', () {
      // 把 0 当成 O 之类的「纠错」会算出永远不对的码，
      // 而用户只会怀疑自己抄错了密钥——这种帮倒忙比报错更贵。
      expect(base32Decode('MZXW6YTB0'), isNull);
      expect(base32Decode('MZXW6YTB1'), isNull);
      expect(base32Decode('中文密钥'), isNull);
      expect(base32Decode(''), isNull);
      expect(base32Decode('   '), isNull);
    });
  });

  group('HOTP（RFC 4226 附录 D）', () {
    test('前十个计数器', () {
      const expected = [
        '755224',
        '287082',
        '359152',
        '969429',
        '338314',
        '254676',
        '287922',
        '162583',
        '399871',
        '520489',
      ];
      for (var counter = 0; counter < expected.length; counter++) {
        expect(
          hotp(rfcSecret, counter),
          expected[counter],
          reason: '计数器 $counter',
        );
      }
    });
  });

  group('TOTP（RFC 6238 附录 B）', () {
    const seconds = [
      59,
      1111111109,
      1111111111,
      1234567890,
      2000000000,
      20000000000,
    ];

    test('SHA1', () {
      const expected = [
        '94287082',
        '07081804',
        '14050471',
        '89005924',
        '69279037',
        '65353130',
      ];
      final config = TotpConfig(secret: rfcSecret, digits: 8);
      for (var i = 0; i < seconds.length; i++) {
        expect(
          codeAtSeconds(config, seconds[i]),
          expected[i],
          reason: '时间 ${seconds[i]}',
        );
      }
    });

    test('SHA256', () {
      // 标准里 256 位与 512 位用更长的密钥，长度不够会得到不同的向量。
      final secret = Uint8List.fromList(
        utf8.encode('12345678901234567890123456789012'),
      );
      const expected = [
        '46119246',
        '68084774',
        '67062674',
        '91819424',
        '90698825',
        '77737706',
      ];
      final config = TotpConfig(
        secret: secret,
        digits: 8,
        algorithm: TotpAlgorithm.sha256,
      );
      for (var i = 0; i < seconds.length; i++) {
        expect(
          codeAtSeconds(config, seconds[i]),
          expected[i],
          reason: '时间 ${seconds[i]}',
        );
      }
    });

    test('SHA512', () {
      final secret = Uint8List.fromList(
        utf8.encode(
          '1234567890123456789012345678901234567890123456789012345678901234',
        ),
      );
      const expected = [
        '90693936',
        '25091201',
        '99943326',
        '93441116',
        '38618901',
        '47863826',
      ];
      final config = TotpConfig(
        secret: secret,
        digits: 8,
        algorithm: TotpAlgorithm.sha512,
      );
      for (var i = 0; i < seconds.length; i++) {
        expect(
          codeAtSeconds(config, seconds[i]),
          expected[i],
          reason: '时间 ${seconds[i]}',
        );
      }
    });

    test('6 位码是 8 位码的后六位', () {
      // 取模位数不同不该改变「同一个时刻算的是同一个中间值」这件事。
      final eight = TotpConfig(secret: rfcSecret, digits: 8);
      final six = TotpConfig(secret: rfcSecret);
      expect(codeAtSeconds(eight, 59), '94287082');
      expect(codeAtSeconds(six, 59), '287082');
    });
  });

  group('时间窗口', () {
    final config = TotpConfig(secret: rfcSecret);

    test('同一个 30 秒窗口内码不变，跨过窗口就变', () {
      expect(codeAtSeconds(config, 30), codeAtSeconds(config, 59));
      expect(codeAtSeconds(config, 60), isNot(codeAtSeconds(config, 59)));
    });

    test('剩余秒数在窗口边界上是周期本身，不是 0', () {
      // 「还剩 0 秒」在界面上等于已过期，但这一刻的码刚生效、还能用整个周期。
      expect(config.remainingAt(DateTime.fromMillisecondsSinceEpoch(0)), 30);
      expect(config.remainingAt(DateTime.fromMillisecondsSinceEpoch(30000)), 30);
      expect(config.remainingAt(DateTime.fromMillisecondsSinceEpoch(31000)), 29);
      expect(config.remainingAt(DateTime.fromMillisecondsSinceEpoch(59000)), 1);
    });

    test('自定义周期', () {
      final sixty = TotpConfig(secret: rfcSecret, period: 60);
      expect(sixty.counterAt(DateTime.fromMillisecondsSinceEpoch(59000)), 0);
      expect(sixty.counterAt(DateTime.fromMillisecondsSinceEpoch(61000)), 1);
      expect(sixty.remainingAt(DateTime.fromMillisecondsSinceEpoch(0)), 60);
    });
  });

  group('解析 otpauth 链接', () {
    test('标准链接的全部参数都读得出来', () {
      final parsed = parseTotp(
        'otpauth://totp/ACME%20Co:john@example.com'
        '?secret=$rfcSecretBase32&issuer=ACME%20Co'
        '&algorithm=SHA1&digits=6&period=30',
      );
      expect(parsed.error, isNull);
      final config = parsed.config!;
      expect(config.secret, rfcSecret);
      expect(config.digits, 6);
      expect(config.period, 30);
      expect(config.algorithm, TotpAlgorithm.sha1);
      expect(config.issuer, 'ACME Co');
      expect(config.account, 'john@example.com');
      expect(config.label, 'ACME Co · john@example.com');
    });

    test('缺省的参数按标准取默认值', () {
      final parsed = parseTotp('otpauth://totp/alice?secret=$rfcSecretBase32');
      expect(parsed.error, isNull);
      expect(parsed.config!.digits, 6);
      expect(parsed.config!.period, 30);
      expect(parsed.config!.algorithm, TotpAlgorithm.sha1);
      expect(parsed.config!.issuer, '');
      expect(parsed.config!.account, 'alice');
      expect(parsed.config!.label, 'alice');
    });

    test('标签里的发行方在缺少 issuer 参数时生效', () {
      final parsed = parseTotp(
        'otpauth://totp/GitHub:octocat?secret=$rfcSecretBase32',
      );
      expect(parsed.config!.issuer, 'GitHub');
      expect(parsed.config!.account, 'octocat');
    });

    test('算法不区分大小写与连字符', () {
      for (final name in ['sha256', 'SHA256', 'SHA-256']) {
        final parsed = parseTotp(
          'otpauth://totp/x?secret=$rfcSecretBase32&algorithm=$name',
        );
        expect(parsed.config?.algorithm, TotpAlgorithm.sha256, reason: name);
      }
    });

    test('用户连提示语一起粘过来也能解析', () {
      final parsed = parseTotp(
        '请在这里输入密钥：otpauth://totp/x?secret=$rfcSecretBase32 谢谢',
      );
      expect(parsed.error, isNull);
      expect(parsed.config!.secret, rfcSecret);
    });

    test('按次数计的 HOTP 要说清楚为什么不支持', () {
      final parsed = parseTotp('otpauth://hotp/x?secret=$rfcSecretBase32');
      expect(parsed.config, isNull);
      expect(parsed.error, contains('按次数'));
    });

    test('缺 secret、位数越界、算法不认识都要报出原因', () {
      expect(parseTotp('otpauth://totp/x').error, contains('secret'));
      expect(
        parseTotp('otpauth://totp/x?secret=$rfcSecretBase32&digits=10').error,
        contains('6 到 8'),
      );
      expect(
        parseTotp('otpauth://totp/x?secret=$rfcSecretBase32&algorithm=MD5').error,
        contains('MD5'),
      );
      expect(
        parseTotp('otpauth://totp/x?secret=$rfcSecretBase32&period=0').error,
        contains('周期'),
      );
    });
  });

  group('解析裸密钥', () {
    test('直接给 Base32 也能用', () {
      final parsed = parseTotp(rfcSecretBase32);
      expect(parsed.config!.secret, rfcSecret);
      expect(parsed.config!.codeAt(DateTime.fromMillisecondsSinceEpoch(59000)),
          '287082');
    });

    test('分组写法的密钥（带空格）', () {
      final grouped = 'GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ';
      expect(parseTotp(grouped).config!.secret, rfcSecret);
    });

    test('空值、非法字符、过短都要给出原因', () {
      expect(parseTotp('').error, contains('空'));
      expect(parseTotp('MZXW6YTB0').error, contains('Base32'));
      expect(parseTotp('AA').error, contains('太短'));
    });
  });
}
