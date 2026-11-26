import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/idle_guard.dart';

/// 自动锁定的核心是「什么时候算没人在」。这里测的就是那个判据本身。
void main() {
  group('IdleGuard 无操作监护', () {
    test('无操作超过阈值回调一次', () async {
      var fired = 0;
      final guard = IdleGuard(
        limit: const Duration(milliseconds: 150),
        tick: const Duration(milliseconds: 20),
      );
      guard.onIdle = () => fired++;
      guard.arm();

      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(fired, 1, reason: '空闲超过阈值应当锁定，且只锁一次');
      guard.disarm();
    });

    test('持续有活动不会锁', () async {
      var fired = 0;
      final guard = IdleGuard(
        limit: const Duration(milliseconds: 150),
        tick: const Duration(milliseconds: 20),
      );
      guard.onIdle = () => fired++;
      guard.arm();

      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        guard.bump();
      }

      expect(fired, 0, reason: '一直在用的人不该被锁');
      guard.disarm();
    });

    test('disarm 后不再回调', () async {
      var fired = 0;
      final guard = IdleGuard(
        limit: const Duration(milliseconds: 120),
        tick: const Duration(milliseconds: 20),
      );
      guard.onIdle = () => fired++;
      guard.arm();
      guard.disarm();

      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(fired, 0, reason: '已解除监护就不该再触发');
    });

    test('未 arm 时 bump 不会启动计时', () async {
      var fired = 0;
      final guard = IdleGuard(
        limit: const Duration(milliseconds: 100),
        tick: const Duration(milliseconds: 20),
      );
      guard.onIdle = () => fired++;
      guard.bump();

      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(fired, 0);
      expect(guard.isArmed, isFalse);
    });
  });
}
