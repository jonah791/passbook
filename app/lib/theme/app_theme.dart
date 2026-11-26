import 'package:flutter/material.dart';

/// 纸与墨。
///
/// 一个日用密码本不该长得像仪表盘——它该像一页安静的纸：暖白底、墨色字、
/// 一根发丝般的分隔线，以及一枚印章色的赤陶。
///
/// **纪律**：强调色只出现在三处——光标、焦点下划线、危险动作。其余层级全部
/// 由字号 / 字重 / 字距 / 留白建立。加任何装饰之前先问：「它在编码什么信息？」
/// 编码不出信息的（阴影、卡片、渐变、全大写标签）就不加。
abstract final class Palette {
  // 昼
  static const paper = Color(0xFFF8F6F1);
  static const paperDeep = Color(0xFFF0EDE5);
  static const ink = Color(0xFF1B1A17);
  static const inkSoft = Color(0xFF6A6659);
  static const inkFaint = Color(0xFFA39E92);
  static const rule = Color(0x1A1B1A17); // 10% 墨：一条真正细的线
  static const seal = Color(0xFFA4553C);

  // 夜
  static const night = Color(0xFF161513);
  static const nightDeep = Color(0xFF1E1D19);
  static const nightInk = Color(0xFFE8E4DA);
  static const nightSoft = Color(0xFF9A9488);
  static const nightFaint = Color(0xFF7A756A); // 比昼间的淡更亮：暗底上的灰会糊成一团
  static const nightRule = Color(0x24E8E4DA);
  static const sealNight = Color(0xFFC97A5E);

  /// 几乎直角。圆角大了就软，软了就廉价。
  static const radius = 2.0;

  /// 正文最大行宽。超过这个宽度眼睛会跳行——桌面上最常见的排版缺陷。
  static const readingWidth = 680.0;

  /// 列表内容最大宽度。全屏时标题与复制按钮不该隔着一整个屏幕。
  static const listWidth = 760.0;
}

/// [fontFamily] 留了口子：生产环境用平台默认字体（Windows 上是 Segoe UI），
/// 截图测试必须显式注入，否则测试环境里的 Ahem 字体把所有字渲染成方块。
ThemeData buildAppTheme(
  Brightness brightness, {
  String? fontFamily,
  List<String>? fontFamilyFallback,
}) {
  final dark = brightness == Brightness.dark;
  final base = dark ? const ColorScheme.dark() : const ColorScheme.light();
  final seal = dark ? Palette.sealNight : Palette.seal;
  final text = dark ? Palette.nightInk : Palette.ink;
  final soft = dark ? Palette.nightSoft : Palette.inkSoft;
  final faint = dark ? Palette.nightFaint : Palette.inkFaint;
  final line = dark ? Palette.nightRule : Palette.rule;
  final surface = dark ? Palette.night : Palette.paper;
  final deep = dark ? Palette.nightDeep : Palette.paperDeep;

  TextStyle style({
    required double size,
    FontWeight? weight,
    double? height,
    double? letterSpacing,
    Color? color,
  }) {
    return TextStyle(
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
    );
  }

  final scheme = base.copyWith(
    primary: seal,
    onPrimary: dark ? Palette.night : Palette.paper,
    secondary: seal,
    onSecondary: dark ? Palette.night : Palette.paper,
    surface: surface,
    onSurface: text,
    surfaceContainerHighest: deep,
    onSurfaceVariant: soft,
    outline: line,
    outlineVariant: line,
    error: dark ? const Color(0xFFE08A78) : const Color(0xFF9C3A2A),
  );

  UnderlineInputBorder underline(Color color, double width) =>
      UnderlineInputBorder(
        borderSide: BorderSide(color: color, width: width),
        borderRadius: BorderRadius.zero,
      );

  // 默认字阶必须整个拿过来再覆盖：只写五项的话，bodyLarge 等为 null，
  // TextField 这类按字阶取默认样式的组件会丢掉字体族，直接渲染成方块。
  final fallbackText =
      (dark
              ? ThemeData.dark(useMaterial3: true)
              : ThemeData.light(useMaterial3: true))
          .textTheme;
  final textTheme = fallbackText
      .copyWith(
        headlineSmall: style(
          size: 22,
          weight: FontWeight.w500,
          letterSpacing: -0.2,
          height: 1.3,
          color: text,
        ),
        titleMedium: style(
          size: 16,
          weight: FontWeight.w500,
          height: 1.35,
          color: text,
        ),
        bodyMedium: style(size: 15, height: 1.6, color: text),
        bodySmall: style(size: 13, height: 1.5, color: soft),
        labelSmall: style(size: 11, letterSpacing: 0.4, color: faint),
      )
      .apply(fontFamily: fontFamily, fontFamilyFallback: fontFamilyFallback);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: surface,
    canvasColor: surface,
    // 水波纹洒在纸上像脏污。桌面端用悬停底色回应，不用 splash。
    splashFactory: NoSplash.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 24,
      foregroundColor: text,
    ),
    dividerTheme: DividerThemeData(color: line, thickness: 0.5, space: 0.5),
    textTheme: textTheme,
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      isDense: true,
      hintStyle: style(size: 14, color: faint),
      contentPadding: const EdgeInsets.symmetric(vertical: 10),
      border: underline(line, 0.5),
      enabledBorder: underline(line, 0.5),
      focusedBorder: underline(seal, 1),
      errorBorder: underline(scheme.error, 0.5),
      focusedErrorBorder: underline(scheme.error, 1),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: seal,
      selectionColor: seal.withValues(alpha: 0.18),
      selectionHandleColor: seal,
    ),
    iconTheme: IconThemeData(color: soft, size: 18),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: seal,
        textStyle: style(size: 14, weight: FontWeight.w500, letterSpacing: 0.2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Palette.radius),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: text,
        foregroundColor: surface,
        elevation: 0,
        textStyle: style(size: 14, weight: FontWeight.w500, letterSpacing: 0.2),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Palette.radius),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? Palette.nightDeep : Palette.ink,
      contentTextStyle: style(
        size: 13,
        color: dark ? Palette.nightInk : Palette.paper,
      ),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Palette.radius),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Palette.radius + 2),
      ),
      titleTextStyle: style(size: 17, weight: FontWeight.w500, color: text),
      contentTextStyle: style(size: 14, height: 1.6, color: soft),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Palette.radius),
        side: BorderSide(color: line, width: 0.5),
      ),
      textStyle: style(size: 14, color: text),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? Palette.nightDeep : Palette.ink,
        borderRadius: BorderRadius.circular(Palette.radius),
      ),
      textStyle: style(
        size: 12,
        color: dark ? Palette.nightInk : Palette.paper,
      ),
      waitDuration: const Duration(milliseconds: 600),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(4),
      radius: const Radius.circular(2),
      thumbColor: WidgetStatePropertyAll(
        (dark ? Palette.nightInk : Palette.ink).withValues(alpha: 0.18),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
