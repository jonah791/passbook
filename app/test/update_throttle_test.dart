import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/update/release.dart';
import 'package:passbook/core/update/update_controller.dart';
import 'package:passbook/core/update/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只数「有没有真去查」，不碰网络。
///
/// 为什么单独一个文件：这里需要 TestWidgetsFlutterBinding（SharedPreferences 的
/// mock 依赖它），而那个 binding 会把所有 HTTP 拦成 400——真网络那套测试
/// 因此必须待在 update_flow_test.dart 里、且不初始化 binding。
class _CountingService extends UpdateService {
  _CountingService({String version = '1.0.0'})
      : super(currentVersion: version, target: UpdateTarget.android);

  int calls = 0;

  @override
  Future<UpdateCheck> check() async {
    calls++;
    return const UpdateCheck.failed('stub：这条测试只数次数');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  UpdateController build(_CountingService service, DateTime now, {String version = '1.0.0'}) {
    return UpdateController(
      service: service,
      clock: () => now,
      versionReader: () async => version,
    );
  }

  test('12 小时内不再请求', () async {
    SharedPreferences.setMockInitialValues({
      'update.lastCheckMs': DateTime(2026, 11, 26, 12).millisecondsSinceEpoch,
    });
    final service = _CountingService();
    final controller = build(service, DateTime(2026, 11, 26, 13));

    await controller.maybeAutoCheck();

    expect(service.calls, 0);
    expect(controller.phase, UpdatePhase.idle);
  });

  test('超过 12 小时会查一次，并把检查时刻写回本地', () async {
    SharedPreferences.setMockInitialValues({
      'update.lastCheckMs': DateTime(2026, 11, 26, 12).millisecondsSinceEpoch,
    });
    final service = _CountingService();
    final controller = build(service, DateTime(2026, 11, 27, 1));

    await controller.maybeAutoCheck();

    expect(service.calls, 1);
    // stub 返回失败：**失败也记时间**，否则断网时会每次启动都重试一遍。
    expect(controller.phase, UpdatePhase.failed);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt('update.lastCheckMs'),
      DateTime(2026, 11, 27, 1).millisecondsSinceEpoch,
    );
  });

  test('首次启动（没有记录）就查一次', () async {
    SharedPreferences.setMockInitialValues({});
    final service = _CountingService();
    final controller = build(service, DateTime(2026, 11, 26, 9));

    await controller.maybeAutoCheck();

    expect(service.calls, 1);
  });

  test('关掉自动检查后不发请求', () async {
    SharedPreferences.setMockInitialValues({'update.auto': false});
    final service = _CountingService();
    final controller = build(service, DateTime(2026, 12, 1));

    await controller.maybeAutoCheck();

    expect(service.calls, 0);
    expect(controller.autoCheck, isFalse);
  });

  test('用户手动点「检查更新」不受 12 小时节流限制', () async {
    SharedPreferences.setMockInitialValues({
      'update.lastCheckMs': DateTime(2026, 11, 26, 12).millisecondsSinceEpoch,
    });
    final service = _CountingService();
    final controller = build(service, DateTime(2026, 11, 26, 12, 1));

    await controller.check();
    await controller.check();

    expect(service.calls, 2);
  });

  test('开关存得下来（下次启动还关着）', () async {
    SharedPreferences.setMockInitialValues({});
    final service = _CountingService();
    final controller = build(service, DateTime(2026, 11, 26, 9));

    await controller.setAutoCheck(false);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('update.auto'), isFalse);

    final reopened = build(service, DateTime(2026, 11, 26, 9));
    await reopened.loadPreferences();
    expect(reopened.autoCheck, isFalse);
  });
}
