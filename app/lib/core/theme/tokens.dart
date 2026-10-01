import 'package:flutter/material.dart';

/// 디자인 토큰 (docs/06 §5.1, prototype/index.html :root 와 1:1).
/// 의미색은 항상 아이콘·텍스트와 함께 쓴다.
@immutable
class ChalloryColors extends ThemeExtension<ChalloryColors> {
  const ChalloryColors({
    required this.bg,
    required this.surface,
    required this.fg,
    required this.fg2,
    required this.border,
    required this.borderStrong,
    required this.brand,
    required this.onBrand,
    required this.brandSoft,
    required this.good,
    required this.goodSoft,
    required this.warn,
    required this.warnSoft,
    required this.critical,
    required this.criticalSoft,
    required this.review,
    required this.reviewSoft,
    required this.ringTrack,
    required this.intake,
    required this.burn,
    required this.onCritical,
    required this.kakao,
    required this.onKakao,
    required this.apple,
    required this.onApple,
  });

  final Color bg;
  final Color surface;
  final Color fg;
  final Color fg2;
  final Color border;
  final Color borderStrong;
  final Color brand;
  final Color onBrand;
  final Color brandSoft;
  final Color good;
  final Color goodSoft;
  final Color warn;
  final Color warnSoft;
  final Color critical;
  final Color criticalSoft;
  final Color review;
  final Color reviewSoft;
  final Color ringTrack;

  /// 섭취/소비 데이터 색
  final Color intake;
  final Color burn;
  final Color onCritical;
  final Color kakao;
  final Color onKakao;
  final Color apple;
  final Color onApple;

  static const light = ChalloryColors(
    bg: Color(0xFFFFFFFF),
    surface: Color(0xFFF4F6F8),
    fg: Color(0xFF1A1C1E),
    fg2: Color(0xFF4A4F55),
    border: Color(0xFFDDE1E6),
    borderStrong: Color(0xFF808992),
    brand: Color(0xFF0B6E70),
    onBrand: Color(0xFFFFFFFF),
    brandSoft: Color(0xFFDCF1F1),
    good: Color(0xFF176F33),
    goodSoft: Color(0xFFE3F5E8),
    warn: Color(0xFF8A5A00),
    warnSoft: Color(0xFFFFF1D6),
    critical: Color(0xFFB3261E),
    criticalSoft: Color(0xFFFBE4E2),
    review: Color(0xFF5B4FCF),
    reviewSoft: Color(0xFFECEAFB),
    ringTrack: Color(0xFF808992),
    intake: Color(0xFFDC6420),
    burn: Color(0xFF0A95A0),
    onCritical: Color(0xFFFFFFFF),
    kakao: Color(0xFFFEE500),
    onKakao: Color(0xFF191919),
    apple: Color(0xFF000000),
    onApple: Color(0xFFFFFFFF),
  );

  static const dark = ChalloryColors(
    bg: Color(0xFF121417),
    surface: Color(0xFF1C1F24),
    fg: Color(0xFFE6E8EB),
    fg2: Color(0xFFA3A9B1),
    border: Color(0xFF2A2F36),
    borderStrong: Color(0xFF6A727C),
    brand: Color(0xFF5FD3D5),
    onBrand: Color(0xFF0B1F20),
    brandSoft: Color(0xFF163F40),
    good: Color(0xFF6CCB84),
    goodSoft: Color(0xFF1B3A25),
    warn: Color(0xFFF2B84B),
    warnSoft: Color(0xFF3D2E0F),
    critical: Color(0xFFFF8A80),
    criticalSoft: Color(0xFF4A1A17),
    review: Color(0xFFB4ACFF),
    reviewSoft: Color(0xFF272352),
    ringTrack: Color(0xFF6A727C),
    intake: Color(0xFFDD7434),
    burn: Color(0xFF1F9EA8),
    onCritical: Color(0xFF2B0B09),
    kakao: Color(0xFFFEE500),
    onKakao: Color(0xFF191919),
    apple: Color(0xFF000000),
    onApple: Color(0xFFFFFFFF),
  );

  @override
  ChalloryColors copyWith({
    Color? bg,
    Color? surface,
    Color? fg,
    Color? fg2,
    Color? border,
    Color? borderStrong,
    Color? brand,
    Color? onBrand,
    Color? brandSoft,
    Color? good,
    Color? goodSoft,
    Color? warn,
    Color? warnSoft,
    Color? critical,
    Color? criticalSoft,
    Color? review,
    Color? reviewSoft,
    Color? ringTrack,
    Color? intake,
    Color? burn,
    Color? onCritical,
    Color? kakao,
    Color? onKakao,
    Color? apple,
    Color? onApple,
  }) {
    return ChalloryColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      fg: fg ?? this.fg,
      fg2: fg2 ?? this.fg2,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      brand: brand ?? this.brand,
      onBrand: onBrand ?? this.onBrand,
      brandSoft: brandSoft ?? this.brandSoft,
      good: good ?? this.good,
      goodSoft: goodSoft ?? this.goodSoft,
      warn: warn ?? this.warn,
      warnSoft: warnSoft ?? this.warnSoft,
      critical: critical ?? this.critical,
      criticalSoft: criticalSoft ?? this.criticalSoft,
      review: review ?? this.review,
      reviewSoft: reviewSoft ?? this.reviewSoft,
      ringTrack: ringTrack ?? this.ringTrack,
      intake: intake ?? this.intake,
      burn: burn ?? this.burn,
      onCritical: onCritical ?? this.onCritical,
      kakao: kakao ?? this.kakao,
      onKakao: onKakao ?? this.onKakao,
      apple: apple ?? this.apple,
      onApple: onApple ?? this.onApple,
    );
  }

  @override
  ChalloryColors lerp(ThemeExtension<ChalloryColors>? other, double t) {
    if (other is! ChalloryColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return ChalloryColors(
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      fg: l(fg, other.fg),
      fg2: l(fg2, other.fg2),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      brand: l(brand, other.brand),
      onBrand: l(onBrand, other.onBrand),
      brandSoft: l(brandSoft, other.brandSoft),
      good: l(good, other.good),
      goodSoft: l(goodSoft, other.goodSoft),
      warn: l(warn, other.warn),
      warnSoft: l(warnSoft, other.warnSoft),
      critical: l(critical, other.critical),
      criticalSoft: l(criticalSoft, other.criticalSoft),
      review: l(review, other.review),
      reviewSoft: l(reviewSoft, other.reviewSoft),
      ringTrack: l(ringTrack, other.ringTrack),
      intake: l(intake, other.intake),
      burn: l(burn, other.burn),
      onCritical: l(onCritical, other.onCritical),
      kakao: l(kakao, other.kakao),
      onKakao: l(onKakao, other.onKakao),
      apple: l(apple, other.apple),
      onApple: l(onApple, other.onApple),
    );
  }
}

extension ChalloryThemeContext on BuildContext {
  ChalloryColors get c => Theme.of(this).extension<ChalloryColors>() ?? ChalloryColors.light;
}
