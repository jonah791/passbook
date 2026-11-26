import 'dart:async';

import 'package:flutter/material.dart';

import '../core/update/release.dart';
import '../core/update/update_controller.dart';
import '../theme/app_theme.dart';

/// 关于与更新。一页装完：版本、更新入口、仓库地址、许可。
///
/// 「关于」页最容易变成装饰：塞一堆图标、版权年份、致谢名单。
/// 这里的纪律是——**每一项都要能回答一个用户真会问的问题**，
/// 答不出的就不放。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.updates});

  final UpdateController updates;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  @override
  void initState() {
    super.initState();
    // 进来就查一次：用户点开这一页，本来就是想问「有没有新版」。
    unawaited(widget.updates.check());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final soft = theme.colorScheme.onSurfaceVariant;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Palette.readingWidth),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 16, 4),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '返回（Esc）',
                          icon: const Icon(Icons.arrow_back_ios_new, size: 15),
                          color: soft,
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                        const SizedBox(width: 8),
                        Text('关于', style: theme.textTheme.titleMedium),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: widget.updates,
                      builder: (context, _) => ListView(
                        padding: const EdgeInsets.fromLTRB(24, 18, 24, 64),
                        children: [
                          Text(
                            'passbook',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.4,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '本地优先的跨端密码本：库在你自己手里，局域网直连同步，'
                            '没有账号，也没有服务器。',
                            style: TextStyle(fontSize: 13, height: 1.7, color: soft),
                          ),
                          const SizedBox(height: 30),

                          _section(theme, '版本与更新'),
                          const SizedBox(height: 14),
                          _versionRow(theme),
                          const SizedBox(height: 16),
                          _updateArea(theme),
                          const SizedBox(height: 22),
                          _autoCheckRow(theme),

                          const SizedBox(height: 34),
                          _section(theme, '仓库'),
                          const SizedBox(height: 12),
                          SelectableText(
                            kRepoUri.toString(),
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontFamily: 'Consolas',
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '自动更新只从 GitHub Releases 取正式版，并且要过 SHA256 校验：'
                            '发布里没有摘要、或摘要对不上，它就不装——宁可让你手动下载，'
                            '也不让你装上没核对过的程序。',
                            style: TextStyle(fontSize: 12.5, height: 1.7, color: soft),
                          ),

                          const SizedBox(height: 34),
                          _section(theme, '其他'),
                          const SizedBox(height: 12),
                          Text(
                            '独立开发的小工具。库文件是标准 KDBX，随时可以拿别的密码管理器打开。',
                            style: TextStyle(fontSize: 12.5, height: 1.7, color: soft),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _versionRow(ThemeData theme) {
    final current = widget.updates.currentVersion;
    return Row(
      children: [
        Text('当前版本', style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(width: 14),
        Text(
          current ?? '读取中…',
          style: const TextStyle(fontSize: 14.5, fontFamily: 'Consolas'),
        ),
      ],
    );
  }

  Widget _updateArea(ThemeData theme) {
    final updates = widget.updates;
    final soft = theme.colorScheme.onSurfaceVariant;
    final phase = updates.phase;

    final statusText = switch (phase) {
      UpdatePhase.idle => null,
      UpdatePhase.checking => updates.message ?? '正在连接 GitHub…',
      UpdatePhase.upToDate => '已是最新版本',
      UpdatePhase.available => null,
      UpdatePhase.downloading => updates.message ?? '正在下载…',
      UpdatePhase.installing => updates.message ?? '正在安装…',
      UpdatePhase.failed => updates.message ?? '检查失败',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (phase == UpdatePhase.available)
              FilledButton(
                onPressed: updates.busy ? null : () => unawaited(updates.downloadAndInstall()),
                child: Text('下载并安装 ${updates.release?.tag ?? ''}'),
              )
            else
              TextButton(
                onPressed: updates.busy ? null : () => unawaited(updates.check()),
                child: Text(
                  switch (phase) {
                    UpdatePhase.checking => '检查中…',
                    UpdatePhase.downloading || UpdatePhase.installing => '进行中…',
                    _ => '检查更新',
                  },
                ),
              ),
            if (phase == UpdatePhase.available || phase == UpdatePhase.upToDate) ...[
              const SizedBox(width: 10),
              Text(
                '最新 ${updates.release?.tag ?? ''}',
                style: TextStyle(fontSize: 12, color: soft),
              ),
            ],
          ],
        ),
        if (statusText != null) ...[
          const SizedBox(height: 10),
          SelectableText(
            statusText,
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: phase == UpdatePhase.failed
                  ? theme.colorScheme.error
                  : soft,
            ),
          ),
        ],
        if (phase == UpdatePhase.downloading) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: updates.progress > 0 ? updates.progress : null,
            minHeight: 2,
            backgroundColor: theme.colorScheme.outline,
          ),
          const SizedBox(height: 6),
          Text(
            '${(updates.progress * 100).toStringAsFixed(0)}%',
            style: TextStyle(fontSize: 11.5, color: soft),
          ),
        ],
        if (phase == UpdatePhase.available && (updates.release?.notes.isNotEmpty ?? false)) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: theme.colorScheme.outline, width: 1),
              ),
            ),
            child: Text(
              _trimNotes(updates.release!.notes),
              style: TextStyle(fontSize: 12.5, height: 1.7, color: soft),
            ),
          ),
        ],
      ],
    );
  }

  Widget _autoCheckRow(ThemeData theme) {
    final updates = widget.updates;
    return Row(
      children: [
        SizedBox(
          width: 36,
          height: 28,
          child: Switch(
            value: updates.autoCheck,
            onChanged: (value) => unawaited(updates.setAutoCheck(value)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '启动时自动检查（每 12 小时最多一次，失败不打扰）',
            style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// 发布说明只截前 900 字：完整内容在 GitHub 上，塞进这一页会把版面撑垮。
  static String _trimNotes(String notes) {
    final text = notes.trim();
    if (text.length <= 900) return text;
    return '${text.substring(0, 900)}…';
  }

  Widget _section(ThemeData theme, String title) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 0.8,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Divider(height: 0.5, color: theme.colorScheme.outline)),
      ],
    );
  }
}
