import 'package:flutter/material.dart';

/// Colours that differ between light and dark.
///
/// Resolved from context via [Palette.of] so a theme switch is a rebuild, not a
/// restart. Identity and state colours live on [Tokens] because they are the
/// same pigment on either paper.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.canvas,
    required this.surface,
    required this.surfaceInset,
    required this.outline,
    required this.textPrimary,
    required this.textSecondary,
  });

  final Color canvas;
  final Color surface;
  final Color surfaceInset;
  final Color outline;
  final Color textPrimary;
  final Color textSecondary;

  static const Palette light = Palette(
    canvas: Color(0xFFFCF9F0),
    surface: Color(0xFFFFFFFF),
    surfaceInset: Color(0xFFF1EDE1),
    outline: Color(0xFF000000),
    textPrimary: Color(0xFF000000),
    textSecondary: Color(0xFF6B6B6B),
  );

  /// Not an inversion: the ink-on-paper relationship is preserved, so the
  /// outline stays black on both papers.
  static const Palette dark = Palette(
    canvas: Color(0xFF15130F),
    surface: Color(0xFF23201A),
    surfaceInset: Color(0xFF2E2A22),
    outline: Color(0xFF000000),
    textPrimary: Color(0xFFF5F1E6),
    textSecondary: Color(0xFFA39C8C),
  );

  static Palette of(BuildContext context) =>
      Theme.of(context).extension<Palette>() ?? light;

  // ---- Coloured type, so use sites stay short -------------------------

  TextStyle get display => Tokens.display.copyWith(color: textPrimary);
  TextStyle get screenTitle => Tokens.screenTitle.copyWith(color: textPrimary);
  TextStyle get cardTitle => Tokens.cardTitle.copyWith(color: textPrimary);
  TextStyle get body => Tokens.body.copyWith(color: textPrimary);
  TextStyle get label => Tokens.label.copyWith(color: textSecondary);
  TextStyle get data => Tokens.data.copyWith(color: textPrimary);
  TextStyle get dataStamp => Tokens.dataStamp.copyWith(color: textSecondary);
  TextStyle get dataSmall => Tokens.dataSmall.copyWith(color: textSecondary);

  /// Hard offset shadow — zero blur, never coloured, never soft. The only
  /// depth cue in the system.
  List<BoxShadow> get shadow => <BoxShadow>[
        BoxShadow(
          color: outline,
          offset: const Offset(Tokens.shadowOffset, Tokens.shadowOffset),
          blurRadius: 0,
        ),
      ];

  BorderSide get side => BorderSide(color: outline, width: Tokens.borderWidth);

  @override
  Palette copyWith({
    Color? canvas,
    Color? surface,
    Color? surfaceInset,
    Color? outline,
    Color? textPrimary,
    Color? textSecondary,
  }) =>
      Palette(
        canvas: canvas ?? this.canvas,
        surface: surface ?? this.surface,
        surfaceInset: surfaceInset ?? this.surfaceInset,
        outline: outline ?? this.outline,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
      );

  @override
  Palette lerp(ThemeExtension<Palette>? other, double t) {
    if (other is! Palette) return this;
    return Palette(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceInset: Color.lerp(surfaceInset, other.surfaceInset, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
    );
  }
}

/// The token layer — the only place in the codebase where a raw colour, size,
/// font name, radius, shadow, or duration is allowed to appear.
///
/// Names describe the *role* a value plays, never what it looks like. Derived
/// from `CLAUDE.md`; do not add a token the design system does not sanction.
class Tokens {
  Tokens._();

  // =====================================================================
  // Identity and state colour — identical in both themes
  // =====================================================================

  /// Primary action — shutter, confirm.
  static const Color accent = Color(0xFFFFD84D);

  /// Pressed state for [accent].
  static const Color accentPressed = Color(0xFFE8C22F);

  /// Verified, authentic, signature valid.
  static const Color statusOk = Color(0xFF5EE9A0);

  /// Tampered, denied, destructive, degraded GPS.
  static const Color statusAlert = Color(0xFFFF7BA0);

  /// Caution, fallback key, unavailable service.
  static const Color statusWarn = Color(0xFFF5E3B0);

  static const Color tintInfo = Color(0xFFA78BFA);
  static const Color tintCool = Color(0xFFC8E85A);

  /// Unsorted, empty, nothing yet.
  static const Color tintNull = Color(0xFFC4C4C4);

  /// Every identity colour above is a light pigment, so glyphs sitting on one
  /// are always black — in both themes.
  static const Color onIdentity = Color(0xFF000000);

  // =====================================================================
  // Type — colourless; colour comes from [Palette]
  // =====================================================================

  /// Display and UI face. Variable; weights 400, 500, 700.
  static const String fontUi = 'SpaceGrotesk';

  /// Data face. Weight 400 only.
  static const String fontData = 'JetBrainsMono';

  static const List<FontVariation> _wRegular = <FontVariation>[
    FontVariation('wght', 400)
  ];
  static const List<FontVariation> _wMedium = <FontVariation>[
    FontVariation('wght', 500)
  ];
  static const List<FontVariation> _wBold = <FontVariation>[
    FontVariation('wght', 700)
  ];

  /// 30 / 700 / UI / -0.02em.
  static const TextStyle display = TextStyle(
    fontFamily: fontUi,
    fontVariations: _wBold,
    fontWeight: FontWeight.w700,
    fontSize: 30,
    letterSpacing: -0.6,
    height: 1.1,
  );

  /// 22 / 700 / UI / -0.01em.
  static const TextStyle screenTitle = TextStyle(
    fontFamily: fontUi,
    fontVariations: _wBold,
    fontWeight: FontWeight.w700,
    fontSize: 22,
    letterSpacing: -0.22,
    height: 1.2,
  );

  /// 15 / 700 / UI.
  static const TextStyle cardTitle = TextStyle(
    fontFamily: fontUi,
    fontVariations: _wBold,
    fontWeight: FontWeight.w700,
    fontSize: 15,
    height: 1.25,
  );

  /// 15 / 400 / UI. Prose only.
  static const TextStyle body = TextStyle(
    fontFamily: fontUi,
    fontVariations: _wRegular,
    fontWeight: FontWeight.w400,
    fontSize: 15,
    height: 1.45,
  );

  /// 12 / 500 / UI / 0.02em.
  static const TextStyle label = TextStyle(
    fontFamily: fontUi,
    fontVariations: _wMedium,
    fontWeight: FontWeight.w500,
    fontSize: 12,
    letterSpacing: 0.24,
  );

  /// 12 / 400 / Data.
  ///
  /// Every number a user might verify goes in this face — a coordinate in a
  /// proportional font instantly looks untrustworthy.
  static const TextStyle data = TextStyle(
    fontFamily: fontData,
    fontSize: 12,
    height: 1.4,
  );

  /// 11 / 400 / Data. The stamp card's coordinate and time lines.
  static const TextStyle dataStamp = TextStyle(
    fontFamily: fontData,
    fontSize: 11,
    height: 1.4,
  );

  /// 10 / 400 / Data / 0.06em. Always rendered uppercase.
  static const TextStyle dataSmall = TextStyle(
    fontFamily: fontData,
    fontSize: 10,
    letterSpacing: 0.6,
  );

  // =====================================================================
  // Geometry
  // =====================================================================

  /// Cards and sheets.
  static const double radiusCard = 16;

  /// Buttons, inputs, icon tiles.
  static const double radiusControl = 12;

  /// Full-bleed panels sit flush.
  static const double radiusFlush = 0;

  static const BorderRadius brCard =
      BorderRadius.all(Radius.circular(radiusCard));
  static const BorderRadius brControl =
      BorderRadius.all(Radius.circular(radiusControl));

  /// Badges only.
  static const BorderRadius brPill = BorderRadius.all(Radius.circular(999));

  /// Every border.
  static const double borderWidth = 2;

  /// The shutter only.
  static const double borderWidthThick = 3;

  static const double shadowOffset = 4;

  /// Pressed elements drop the shadow and translate by this much, so the press
  /// reads as physical.
  static const Offset pressShift = Offset(2, 2);

  // Spacing scale: 4, 8, 12, 16, 24, 32. Nothing between.
  static const double spaceHair = 4;
  static const double spaceTight = 8;
  static const double spaceSnug = 12;
  static const double spaceBase = 16;
  static const double spaceSection = 24;
  static const double spaceScreen = 32;

  /// Minimum touch target. Field users wear gloves.
  static const double touchMin = 48;

  /// Icon tile — the visual anchor of every card.
  static const double tileSize = 48;

  /// Shutter face.
  static const double shutterSize = 64;

  /// Control-row and log thumbnail.
  static const double thumbSize = 56;

  /// Numbered check bullet.
  static const double markSize = 24;

  /// Fixed label column in a DataLine, so values align down the page.
  static const double labelColumnWidth = 104;

  /// Upper bound for pinch-zoom on a reviewed frame.
  static const double zoomMaxScale = 5;

  static const double iconSmall = 14;
  static const double iconBase = 20;
  static const double iconTile = 24;

  // =====================================================================
  // Motion
  // =====================================================================
  //
  // Animation only where it communicates a state change. Nothing decorative,
  // nothing above 200ms.

  static const Duration motionFast = Duration(milliseconds: 90);
  static const Duration motionBase = Duration(milliseconds: 180);

  /// Honour the platform's reduced-motion setting.
  static Duration motion(BuildContext context, Duration d) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
          ? Duration.zero
          : d;

  // =====================================================================
  // Themes
  // =====================================================================

  static ThemeData light() => _build(Palette.light, Brightness.light);
  static ThemeData dark() => _build(Palette.dark, Brightness.dark);

  static ThemeData _build(Palette p, Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
      ).copyWith(
        primary: accent,
        onPrimary: onIdentity,
        secondary: statusOk,
        surface: p.surface,
        onSurface: p.textPrimary,
        error: statusAlert,
      ),
      extensions: <ThemeExtension<dynamic>>[p],
      scaffoldBackgroundColor: p.canvas,
      fontFamily: fontUi,
      splashFactory: InkRipple.splashFactory,
      dividerColor: p.outline,
      appBarTheme: AppBarTheme(
        backgroundColor: p.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: screenTitle.copyWith(color: p.textPrimary),
        iconTheme: IconThemeData(color: p.textPrimary),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.textPrimary,
        contentTextStyle: body.copyWith(color: p.canvas),
        shape: const RoundedRectangleBorder(borderRadius: brControl),
      ),
      // Material seeds DefaultTextStyle from bodyMedium, so colourless styles
      // passed to Text inherit the right ink for the active theme.
      textTheme: TextTheme(
        bodyMedium: body.copyWith(color: p.textPrimary),
        bodySmall: label.copyWith(color: p.textSecondary),
        titleMedium: screenTitle.copyWith(color: p.textPrimary),
      ),
    );
  }
}
