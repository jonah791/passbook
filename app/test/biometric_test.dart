import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/biometric.dart';
import 'package:passbook/core/secure_store.dart';

/// 生物识别解锁的判据，重点在**失败的形状**：
/// 验证没过不许写、写入失败不许留半截、没开启不许弹窗打扰。
///
/// 平台能力与密钥库都换成假实现——真实实现要真指纹硬件与系统密钥库，
/// 单测里拿不到；这里测的是「编排对不对」，不是「指纹硬件好不好」。
void main() {
  late _FakePlatform platform;
  late _FakeStore store;
  late BiometricUnlock bio;

  setUp(() {
    platform = _FakePlatform();
    store = _FakeStore();
    bio = BiometricUnlock(platform: platform, store: store);
  });

  group('开关状态', () {
    test('没开过时是关着的', () async {
      expect(await bio.isEnabled(), isFalse);
    });

    test('密钥库读出错时按「关着」处理，不抛', () async {
      store.failRead = true;
      expect(await bio.isEnabled(), isFalse);
    });

    test('设备能不能用，与开没开启是两件事', () async {
      expect(await bio.isSupported(), isTrue);
      expect(await bio.isEnabled(), isFalse);
    });

    test('硬件在但密钥库不可用，也就不算支持', () async {
      store.availableOk = false;
      expect(
        await bio.isSupported(),
        isFalse,
        reason: '存不下就别把功能显示成可用——那只会变成每次开启都失败',
      );
    });
  });

  group('开启', () {
    test('验证通过后把密码存进密钥库', () async {
      expect(await bio.enable('correct horse'), isTrue);
      expect(store.data[BiometricUnlock.keyName], 'correct horse');
      expect(await bio.isEnabled(), isTrue);
      expect(platform.verifyCalls, 1);
    });

    test('验证没过就不写任何东西', () async {
      platform.passes = false;
      expect(await bio.enable('correct horse'), isFalse);
      expect(store.data, isEmpty);
      expect(await bio.isEnabled(), isFalse);
    });

    test('设备不支持时不弹验证、也不写', () async {
      platform.supported = false;
      expect(await bio.enable('correct horse'), isFalse);
      expect(platform.verifyCalls, 0, reason: '不支持就不该先打扰用户一次');
      expect(store.data, isEmpty);
    });

    test('空密码直接拒，不弹验证', () async {
      expect(await bio.enable(''), isFalse);
      expect(platform.verifyCalls, 0);
    });

    test('写入失败要回滚干净，不留半截状态', () async {
      store.failWrite = true;
      expect(await bio.enable('correct horse'), isFalse);
      expect(await bio.isEnabled(), isFalse);
      expect(store.deleted, contains(BiometricUnlock.keyName));
    });
  });

  group('用指纹取密码', () {
    test('开启后验证通过就取到原来那个密码', () async {
      await bio.enable('correct horse');
      platform.verifyCalls = 0;
      expect(await bio.takePassword(), 'correct horse');
      expect(platform.verifyCalls, 1);
    });

    test('没开启时不该弹验证打扰用户', () async {
      expect(await bio.takePassword(), isNull);
      expect(platform.verifyCalls, 0);
    });

    test('验证没过就是拿不到', () async {
      await bio.enable('correct horse');
      platform.passes = false;
      expect(await bio.takePassword(), isNull);
    });

    test('密钥库读出错时拿不到，不抛', () async {
      await bio.enable('correct horse');
      store.failRead = true;
      expect(await bio.takePassword(), isNull);
    });

    test('存的是一段空白等于没存', () async {
      store.data[BiometricUnlock.keyName] = '';
      expect(await bio.isEnabled(), isFalse);
      expect(await bio.takePassword(), isNull);
    });
  });

  group('关闭', () {
    test('关掉之后密钥库里没有东西了', () async {
      await bio.enable('correct horse');
      await bio.disable();
      expect(store.data, isEmpty);
      expect(await bio.isEnabled(), isFalse);
    });

    test('本来就没开，关闭也算成功（幂等）', () async {
      await bio.disable();
      expect(await bio.isEnabled(), isFalse);
    });

    test('删除失败也不抛——调用方要复读状态，别拿「没报错」当「删干净了」', () async {
      await bio.enable('correct horse');
      store.failDelete = true;
      await bio.disable();
      // 删没成功，所以它还是开着的：这里如实暴露，而不是假装关上了。
      expect(await bio.isEnabled(), isTrue);
    });

    test('忘了密码（改过主密码）走 forget，等价于关闭', () async {
      await bio.enable('old pass');
      await bio.forget();
      expect(await bio.isEnabled(), isFalse);
    });
  });
}

class _FakePlatform implements BiometricPlatform {
  bool supported = true;
  bool passes = true;
  int verifyCalls = 0;
  String? lastReason;

  @override
  Future<bool> available() async => supported;

  @override
  Future<bool> verify(String reason) async {
    verifyCalls++;
    lastReason = reason;
    return passes;
  }
}

class _FakeStore implements SecretStore {
  final Map<String, String> data = <String, String>{};
  final Set<String> deleted = <String>{};
  bool availableOk = true;
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;

  @override
  Future<bool> available() async => availableOk;

  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('密钥库读失败');
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('密钥库写失败');
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('密钥库删失败');
    data.remove(key);
    deleted.add(key);
  }
}
