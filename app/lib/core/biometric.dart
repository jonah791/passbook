import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

import 'secure_store.dart';

/// 指纹 / 面容解锁。
///
/// 它做两件必须分开看的事：
///   1. **验证**——弹系统的生物识别界面，只有本人能过；
///   2. **取密码**——验证通过了，从系统密钥库把主密码拿出来，直接开库。
///
/// 代价写在明处：为了做到「验证通过后不必再输密码」，主密码确实**被多存了一份**
/// 在系统密钥库（安卓 Keystore / Windows 凭据管理器）。它不再只存在于你脑子里。
/// 设备被 root、系统密钥库被攻破时，那一份可能被取出。
///
/// 所以它是**省事的快捷方式**，不是**更强的加密**——这是两件事，别混。
/// 库文件本身的强度一点没变：主密码仍是唯一的钥匙，指纹只是把「取出钥匙」这一步
/// 从「手打」换成「按一下」，安全上限由那把钥匙决定，不由指纹决定。
class BiometricUnlock {
  BiometricUnlock({BiometricPlatform? platform, SecretStore? store})
    : _platform = platform ?? LocalAuthPlatform(),
      _store = store ?? const PlatformSecretStore();

  /// 存主密码用的键。带前缀是为了将来存别的东西时不会撞上。
  static const String keyName = 'master-password';

  final BiometricPlatform _platform;
  final SecretStore _store;

  /// 能不能用 = 硬件可用 **且** 存得下。
  ///
  /// 两件事要一起判：只有硬件、没有系统密钥库时（比如桌面端），
  /// 把功能显示成可用只会变成「每次开启都失败」，不如如实说不支持。
  Future<bool> isSupported() async {
    if (!await _platform.available()) return false;
    return _store.available();
  }

  /// 是否已开启。以密钥库里有没有那份密码为准，不信内存里的标志位。
  Future<bool> isEnabled() async {
    try {
      final value = await _store.read(keyName);
      return value != null && value.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 开启：先验证一次（证明是本人），再把密码存进密钥库。
  ///
  /// 验证没过、设备不支持、写入失败，都返回 false，并且**不留半截状态**——
  /// 存了一半比没存更糟：用户以为开了，下次却解不开。
  Future<bool> enable(String password) async {
    if (password.isEmpty) return false;
    if (!await isSupported()) return false;
    if (!await _platform.verify('开启指纹解锁')) return false;
    try {
      await _store.write(keyName, password);
    } catch (_) {
      await disable();
      return false;
    }
    return true;
  }

  /// 关闭。幂等：本来就没开也算成功。
  Future<void> disable() async {
    try {
      await _store.delete(keyName);
    } catch (_) {
      // 删不掉（密钥库坏了）也不抛：上层要判状态就复读 isEnabled()，
      // 不要拿「这里没报错」当「已经删干净」。
    }
  }

  /// 用指纹取主密码。
  ///
  /// 没开启、验证没过、读不出来——一律返回 null。三者对调用方是同一件事
  /// （这次用不了指纹），退回手输就好，不必区分是哪一种。
  Future<String?> takePassword() async {
    if (!await isEnabled()) return null;
    if (!await _platform.verify('解锁 passbook')) return null;
    try {
      final value = await _store.read(keyName);
      if (value == null || value.isEmpty) return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  /// 取出来的密码打不开库（改过主密码，或者换了一个库）时调用。
  ///
  /// 留着它只会让之后每次指纹解锁都注定失败，还要多等一次验证。
  Future<void> forget() => disable();
}

/// 平台验证能力。抽成接口是为了单元测试能换成假实现，不去碰真实平台通道。
abstract class BiometricPlatform {
  /// 硬件在、已录入生物特征、且这平台有实现。
  Future<bool> available();

  /// 弹系统验证界面。通过返回 true；取消 / 不匹配 / 报错都返回 false。
  Future<bool> verify(String reason);
}

/// 真实实现：走 local_auth。
class LocalAuthPlatform implements BiometricPlatform {
  LocalAuthPlatform([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// 能不能用——**只认生物特征**。
  ///
  /// 设备设了 PIN 却没录指纹时 `isDeviceSupported()` 同样是 true，
  /// 那不是我们要的「指纹解锁」，所以还要问 getAvailableBiometrics() 要一份非空。
  @override
  Future<bool> available() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      final enrolled = await _auth.getAvailableBiometrics();
      return enrolled.isNotEmpty;
    } catch (_) {
      // 平台没实现（某些桌面环境）、插件未注册、读硬件失败——都是「用不了」。
      return false;
    }
  }

  @override
  Future<bool> verify(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // 只要生物特征，不许拿设备 PIN 顶。允许 PIN 等于把主密码的强度
        // 降成设备 PIN——那不是这个功能想做的事。
        biometricOnly: true,
        // 验证途中切走再回来（比如去看一眼验证码）不该让这次验证作废。
        persistAcrossBackgrounding: true,
        authMessages: [
          AndroidAuthMessages(
            signInTitle: reason,
            signInHint: '按下指纹传感器',
            cancelButton: '取消',
          ),
        ],
      );
    } catch (_) {
      // LocalAuthException（没录入 / 连错太多次被锁 / 硬件不可用）、
      // PlatformException、MissingPluginException——对调用方都是「没验证过」。
      return false;
    }
  }
}

