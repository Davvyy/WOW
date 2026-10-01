import 'package:flutter/material.dart';

import 'tokens.dart';

export 'tokens.dart';

/// 본문 서체(Pretendard, 앱 번들) / 숫자 전용 서체(Barlow Semi Condensed).
/// 숫자 서체는 한글 글리프가 없어 숫자·단위 ASCII에만 쓴다(docs/06 §5.2).
const kBodyFont = 'Pretendard';
const kNumFont = 'BarlowSemiCondensed';
const kFontFallback = ['Noto Sans KR', 'Apple SD Gothic Neo', 'Malgun Gothic'];

/// 기준 본문 크기 15 (docs/06 §5.2 body 15/22).
class T {
  T._();

  static TextStyle body(ChalloryColors c, {double size = 15, FontWeight w = FontWeight.w400, Color? color}) => TextStyle(
        fontFamily: kBodyFont,
        fontFamilyFallback: kFontFallback,
        fontSize: size,
        height: 1.47,
        fontWeight: w,
        color: color ?? c.fg,
      );

  /// 숫자 표시(tabular). 큰 숫자는 letterSpacing -0.02em.
  static TextStyle num(Color color, {double size = 17, FontWeight w = FontWeight.w600}) => TextStyle(
        fontFamily: kNumFont,
        fontFamilyFallback: const [kBodyFont, ...kFontFallback],
        fontSize: size,
        height: 1.15,
        fontWeight: w,
        color: color,
        letterSpacing: size >= 28 ? -0.02 * size : -0.01 * size,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? ChalloryColors.dark : ChalloryColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.brand,
    onPrimary: c.onBrand,
    primaryContainer: c.brandSoft,
    onPrimaryContainer: c.brand,
    secondary: c.brand,
    onSecondary: c.onBrand,
    error: c.critical,
    onError: c.onCritical,
    errorContainer: c.criticalSoft,
    onErrorContainer: c.critical,
    surface: c.bg,
    onSurface: c.fg,
    onSurfaceVariant: c.fg2,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surface,
    surfaceContainerHighest: c.surface,
    outline: c.borderStrong,
    outlineVariant: c.border,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: kBodyFont,
    fontFamilyFallback: kFontFallback,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    dividerColor: c.border,
    splashFactory: NoSplash.splashFactory,
    extensions: [c],
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: c.fg, displayColor: c.fg, fontFamily: kBodyFont, fontFamilyFallback: kFontFallback),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 56,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.fg,
      contentTextStyle: T.body(c, color: c.bg, w: FontWeight.w500),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
