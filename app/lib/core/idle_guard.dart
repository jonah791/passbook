import 'dart:async';

/// 无操作监护：记录最后一次键鼠活动，空闲超过 [limit] 时回调 [onIdle]。
///
/// 只做计时，不决定「锁不锁」——决策归页面（只有它知道此刻是否已解锁）。
/// 事件捕获挂在应用最外层（见 `main.dart`），因此编辑页、弹窗、滚动都算活动；
/// 收窄在页面里做的话，push 上去的编辑页会收不到指针事件而误锁。
class IdleGuard {
  IdleGuard({
    this.limit = const Duration(minutes: 5),
    this.tick = const Duration(seconds: 1),
  });

  /// 空闲阈值。密码本低于 5 分钟会频繁打断抄录，高于 10 分钟失去意义。
  final Duration limit;

  /// 检查周期。1 秒一跳：锁定最多迟到 1 秒，而持续计时器比「每次活动重建定时器」
  /// 简单得多，也不会因为某类事件没捕获到就永远不锁。测试用小值。
  final Duration tick;

  /// 空闲超时回调。页面在 initState 里挂上，dispose 里清掉。
  void Function()? onIdle;

  DateTime _last = DateTime.now();
  Timer? _ticker;
  bool _armed = false;

  bool get isArmed => _armed;

  /// 开始计时：解锁成功时调用（计时从这一刻起算，不把解锁前的等待算进去）。
  void arm() {
    _armed = true;
    _last = DateTime.now();
    _ticker?.cancel();
    _ticker = Timer.periodic(tick, (_) => _check());
  }

  /// 停止计时：已锁定、或正在锁定。
  void disarm() {
    _armed = false;
    _ticker?.cancel();
    _ticker = null;
  }

  /// 记一次活动。任意指针 / 键盘事件都走这里。
  void bump() {
    if (_armed) _last = DateTime.now();
  }

  /// 还剩多久锁定（锁定页要显示读数时用）。
  Duration get remaining {
    final idle = DateTime.now().difference(_last);
    return idle >= limit ? Duration.zero : limit - idle;
  }

  void _check() {
    if (!_armed) return;
    if (DateTime.now().difference(_last) < limit) return;
    // 先停表再回调：回调里会 close 数据库，重入会二次触发。
    disarm();
    onIdle?.call();
  }
}
