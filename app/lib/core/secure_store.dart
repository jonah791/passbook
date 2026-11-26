import 'package:flutter/services.dart';

/// 主密码的加密存放处。
///
/// 抽成接口有两个用处：单元测试换成内存实现；不同平台各自的实现
/// （有没有系统密钥库）由 [available] 如实回答。
abstract class SecretStore {
  /// 这台设备能不能存。答 false 时上层不该把功能显示成「可用」。
  Future<bool> available();

  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 真实实现：走本机通道 `passbook/secure`。
///
/// 安卓侧把值用 AndroidKeyStore 里一把**不可导出**的 AES 密钥加密后
/// 落到 SharedPreferences（见 android/.../SecureStore.kt）。
/// 桌面端没有这条通道，[available] 会返回 false——于是整套指纹解锁
/// 在桌面上如实不可用，而不是给一个点了没反应的开关。
class PlatformSecretStore implements SecretStore {
  const PlatformSecretStore();

  static const MethodChannel _channel = MethodChannel('passbook/secure');

  @override
  Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      // MissingPluginException（桌面端没注册这条通道）
      // 与 PlatformException（密钥库不可用）对上层是同一件事：这里存不了。
      return false;
    }
  }

  @override
  Future<String?> read(String key) async {
    return _channel.invokeMethod<String>('read', <String, Object?>{
      'key': key,
    });
  }

  @override
  Future<void> write(String key, String value) async {
    await _channel.invokeMethod<void>('write', <String, Object?>{
      'key': key,
      'value': value,
    });
  }

  @override
  Future<void> delete(String key) async {
    await _channel.invokeMethod<void>('delete', <String, Object?>{'key': key});
  }
}
