import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/sync_lan.dart';

/// 二维码里装的东西：生成与解析。
///
/// 这一层值得单测，因为它顶替的正是「人抄三样东西」——抄错一次就是一次
/// 连不上，而连接失败的报错完全指不到「地址写错了」这一步（实测抄成了
/// WSL 的虚拟网卡，对端只回一个 502）。
void main() {
  group('生成', () {
    test('形状是 passbook://sync?...', () {
      const offer = SyncOffer(host: '192.168.1.7', port: 42545, code: '729980');
      final text = offer.toUri();
      expect(text, startsWith('passbook://sync?'));
      expect(text, contains('host=192.168.1.7'));
      expect(text, contains('port=42545'));
      expect(text, contains('code=729980'));
    });

    test('生成的能被自己解析回来', () {
      const offer = SyncOffer(host: '10.0.2.2', port: 8123, code: '123456');
      final back = SyncOffer.tryParse(offer.toUri());
      expect(back, isNotNull);
      expect(back!.host, '10.0.2.2');
      expect(back.port, 8123);
      expect(back.code, '123456');
    });
  });

  group('解析', () {
    test('本应用的 URI', () {
      final offer = SyncOffer.tryParse(
        'passbook://sync?host=192.168.50.204&port=42545&code=729980',
      );
      expect(offer?.host, '192.168.50.204');
      expect(offer?.port, 42545);
      expect(offer?.code, '729980');
    });

    test('参数顺序任意', () {
      final offer = SyncOffer.tryParse(
        'passbook://sync?code=729980&port=42545&host=192.168.50.204',
      );
      expect(offer?.host, '192.168.50.204');
    });

    test('三段纯文本也收：别的扫码工具常把人看得到的内容原样显示', () {
      expect(SyncOffer.tryParse('192.168.1.7 42545 729980')?.port, 42545);
      expect(SyncOffer.tryParse('192.168.1.7,42545,729980')?.code, '729980');
    });

    test('不是本应用的码就拒绝，别拿错的码去敲对端的门', () {
      expect(SyncOffer.tryParse('https://example.com'), isNull);
      expect(SyncOffer.tryParse(''), isNull);
      expect(SyncOffer.tryParse('随便一段文字'), isNull);
      // 码不是六位数字
      expect(
        SyncOffer.tryParse('passbook://sync?host=1.2.3.4&port=80&code=12'),
        isNull,
      );
      expect(
        SyncOffer.tryParse('passbook://sync?host=1.2.3.4&port=80&code=abcdef'),
        isNull,
      );
      // 端口越界
      expect(
        SyncOffer.tryParse(
          'passbook://sync?host=1.2.3.4&port=99999&code=123456',
        ),
        isNull,
      );
      // 缺字段
      expect(
        SyncOffer.tryParse('passbook://sync?host=1.2.3.4&port=80'),
        isNull,
      );
    });
  });
}
