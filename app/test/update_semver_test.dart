import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/update/semver.dart';

/// 版本比较的判据全部写死在这里：自动更新的每一次误判都源于这一层。
void main() {
  group('SemVer 解析', () {
    test('接受 v 前缀、三段号、预发布与构建号', () {
      expect(SemVer.tryParse('1.2.3'), const SemVer(1, 2, 3));
      expect(SemVer.tryParse('v1.2.3'), const SemVer(1, 2, 3));
      expect(SemVer.tryParse('V1.2.3'), const SemVer(1, 2, 3));
      expect(SemVer.tryParse('1.2.3+build.7'), const SemVer(1, 2, 3));
      expect(SemVer.tryParse('v1.2.3-beta.1')?.pre, 'beta.1');
      expect(SemVer.tryParse(' 1.2.3 ')?.toString(), '1.2.3');
    });

    test('解析不出来返回 null，绝不退化成 0.0.0', () {
      // 退化会让「最新版」静默变成「你没有新版」——一次检查失败的读数
      // 会被读成「已是最新」，这正是最坏的形状。
      expect(SemVer.tryParse(null), isNull);
      expect(SemVer.tryParse(''), isNull);
      expect(SemVer.tryParse('nightly'), isNull);
      expect(SemVer.tryParse('1.2'), isNull);
      expect(SemVer.tryParse('release-1.2.3'), isNull);
      expect(SemVer.tryParse('1.2.3.4'), isNull);
    });

    test('多位数按数值比，不按字符串比', () {
      expect(SemVer.tryParse('1.10.0')!.isNewerThan(SemVer.tryParse('1.9.9')!), isTrue);
    });
  });

  group('SemVer 比较', () {
    test('主次修订依次优先', () {
      expect(SemVer.tryParse('2.0.0')!.isNewerThan(SemVer.tryParse('1.99.99')!), isTrue);
      expect(SemVer.tryParse('1.3.0')!.isNewerThan(SemVer.tryParse('1.2.99')!), isTrue);
      expect(SemVer.tryParse('1.2.4')!.isNewerThan(SemVer.tryParse('1.2.3')!), isTrue);
    });

    test('同号相等', () {
      expect(SemVer.tryParse('v1.2.3')!.compareTo(SemVer.tryParse('1.2.3')!), 0);
      expect(SemVer.tryParse('1.2.3')!.isNewerThan(SemVer.tryParse('1.2.3')!), isFalse);
    });

    test('正式版排在预发布版之后（semver §11.3）', () {
      final release = SemVer.tryParse('1.2.3')!;
      final beta = SemVer.tryParse('1.2.3-beta.1')!;
      expect(release.isNewerThan(beta), isTrue);
      expect(beta.isNewerThan(release), isFalse);
      expect(release.isPrerelease, isFalse);
      expect(beta.isPrerelease, isTrue);
    });

    test('预发布标识符按 semver 规则排序', () {
      final ordered = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ].map((raw) => SemVer.tryParse(raw)!).toList();
      for (var i = 1; i < ordered.length; i++) {
        expect(
          ordered[i].isNewerThan(ordered[i - 1]),
          isTrue,
          reason: '${ordered[i]} 应比 ${ordered[i - 1]} 新',
        );
      }
    });
  });
}
