import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'installer.dart';
import 'release.dart';
import 'semver.dart';
import 'update_service.dart';

/// 界面上要区分的六个时刻。合成三档（检查中 / 有新版 / 出错）会丢掉
/// 「正在下载的进度」与「正在等进程退出」这两种需要用户等着看的状态。
enum UpdatePhase { idle, checking, upToDate, available, downloading, installing, failed }

/// 自动更新的状态机。界面只读它，不自己发请求——一处判断，一处降级。
class UpdateController extends ChangeNotifier {
  UpdateController({
    UpdateService? service,
    UpdateInstaller? installer,
    Future<SharedPreferences> Function()? preferences,
    DateTime Function()? clock,
    Future<String> Function()? versionReader,
    void Function()? onNeedExit,
    this.autoCheckInterval = const Duration(hours: 12),
  })  : _service = service,
        _installer = installer,
        _preferences = preferences ?? SharedPreferences.getInstance,
        _clock = clock ?? DateTime.now,
        _versionReader = versionReader ?? _packageVersion,
        _onNeedExit = onNeedExit;

  static const String _kLastCheck = 'update.lastCheckMs';
  static const String _kAutoCheck = 'update.auto';

  final UpdateService? _service;
  final UpdateInstaller? _installer;
  final Future<SharedPreferences> Function() _preferences;
  final DateTime Function() _clock;
  final Future<String> Function() _versionReader;
  final void Function()? _onNeedExit;
  final Duration autoCheckInterval;

  UpdatePhase _phase = UpdatePhase.idle;
  UpdatePhase get phase => _phase;

  String? _currentVersion;
  String? get currentVersion => _currentVersion;

  SemVer? _latestVersion;
  SemVer? get latestVersion => _latestVersion;

  ReleaseInfo? _release;
  ReleaseInfo? get release => _release;

  ReleaseAsset? _asset;
  ReleaseAsset? get asset => _asset;

  String? _message;
  String? get message => _message;

  double _progress = 0;
  double get progress => _progress;

  bool _autoCheck = true;
  bool get autoCheck => _autoCheck;

  bool get hasUpdate => _phase == UpdatePhase.available;
  bool get busy => _phase == UpdatePhase.checking || _phase == UpdatePhase.downloading || _phase == UpdatePhase.installing;

  static Future<String> _packageVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  static void _defaultExit() => exit(0);

  Future<SharedPreferences?> _tryPrefs() async {
    try {
      return await _preferences();
    } on Object {
      // 设置存不下不该让「检查更新」也一起坏掉：读不到就当没有记录。
      return null;
    }
  }

  /// 读一次自动检查开关（界面初始化时调）。
  Future<void> loadPreferences() async {
    final prefs = await _tryPrefs();
    if (prefs == null) return;
    final stored = prefs.getBool(_kAutoCheck);
    if (stored != null && stored != _autoCheck) {
      _autoCheck = stored;
      notifyListeners();
    }
  }

  Future<void> setAutoCheck(bool value) async {
    if (_autoCheck == value) return;
    _autoCheck = value;
    notifyListeners();
    final prefs = await _tryPrefs();
    await prefs?.setBool(_kAutoCheck, value);
  }

  /// 启动时调：距上次检查不足 [autoCheckInterval] 就静默跳过。
  /// 失败**不打扰**用户（没有网络不该在开库时弹错误），但仍记下时间以免反复重试。
  Future<void> maybeAutoCheck() async {
    await loadPreferences();
    if (!_autoCheck) return;
    final prefs = await _tryPrefs();
    final last = prefs?.getInt(_kLastCheck);
    if (last != null) {
      final elapsed = _clock().millisecondsSinceEpoch - last;
      if (elapsed >= 0 && elapsed < autoCheckInterval.inMilliseconds) return;
    }
    await check(silent: true);
  }

  /// 检查更新。[silent] 为真时失败不写成显眼的错误（只记在 [message] 里）。
  Future<void> check({bool silent = false}) async {
    if (busy) return;
    _phase = UpdatePhase.checking;
    _message = silent ? null : '正在连接 GitHub…';
    notifyListeners();

    final result = await _resolveServiceAndCheck();
    if (result == null) {
      _fail('本机版本号读不出来');
      return;
    }

    switch (result.kind) {
      case UpdateCheckKind.upToDate:
        _phase = UpdatePhase.upToDate;
        _currentVersion = result.current?.toString() ?? _currentVersion;
        _latestVersion = result.latest;
        _release = result.release;
        _asset = null;
        _message = '已是最新版本';
        break;
      case UpdateCheckKind.updateAvailable:
        _phase = UpdatePhase.available;
        _currentVersion = result.current?.toString() ?? _currentVersion;
        _latestVersion = result.latest;
        _release = result.release;
        _asset = result.asset;
        _message = '发现新版本 ${result.release?.tag}';
        break;
      case UpdateCheckKind.failed:
        _phase = UpdatePhase.failed;
        _message = result.message ?? '检查失败';
        break;
    }
    final prefs = await _tryPrefs();
    await prefs?.setInt(_kLastCheck, _clock().millisecondsSinceEpoch);
    notifyListeners();
  }

  Future<UpdateCheck?> _resolveServiceAndCheck() async {
    try {
      _currentVersion ??= await _versionReader();
    } on Object catch (e) {
      debugPrint('读版本号失败：$e');
      return null;
    }
    final service = _service ?? UpdateService(currentVersion: _currentVersion!);
    try {
      return await service.check();
    } on Object catch (e) {
      return UpdateCheck.failed('检查失败：$e');
    }
  }

  /// 下载 → 校验 → 安装。每一步失败都停在原地并说清原因，不做静默降级。
  Future<void> downloadAndInstall() async {
    if (_phase != UpdatePhase.available) return;
    final release = _release;
    final asset = _asset;
    if (release == null || asset == null) {
      _fail('没有可安装的产物');
      return;
    }
    final installer = _installer ?? installerForPlatform();
    if (installer == null) {
      _fail('本平台不支持自动安装，请手动去 ${release.htmlUrl} 下载');
      return;
    }

    _phase = UpdatePhase.downloading;
    _progress = 0;
    _message = '正在下载 ${asset.name}…';
    notifyListeners();

    File artifact;
    try {
      final service = _service ?? UpdateService(currentVersion: _currentVersion ?? '0.0.0');
      artifact = await service.download(
        release: release,
        asset: asset,
        onProgress: (value) {
          _progress = value;
          notifyListeners();
        },
      );
    } on Object catch (e) {
      _fail('$e');
      return;
    }

    _phase = UpdatePhase.installing;
    _message = '下载完成，正在安装…';
    notifyListeners();

    try {
      await installer.apply(artifact);
    } on Object catch (e) {
      _fail('安装失败：$e');
      return;
    }

    if (Platform.isWindows) {
      _message = '正在退出以完成替换，几秒后会自动打开新版本…';
      notifyListeners();
      // 让界面把上面这句画出来再退；退晚了 exe 仍被锁着，替换会失败。
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final onExit = _onNeedExit ?? _defaultExit;
      onExit();
    } else {
      _message = '安装器已打开，按提示完成安装即可';
      notifyListeners();
    }
  }

  void _fail(String reason) {
    _phase = UpdatePhase.failed;
    _message = reason;
    notifyListeners();
  }
}
