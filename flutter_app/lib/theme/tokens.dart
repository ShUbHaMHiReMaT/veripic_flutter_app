import 'package:flutter/material.dart';

/// The token layer — the only place in the codebase where a raw colour, size,
/// font name, radius, shadow, or duration is allowed to appear.
///
/// Names describe the *role* a value plays, never what it looks like, so a
/// palette change never invalidates a name. Derived from `CLAUDE.md`; do not
/// add a token the design system does not sanction.
class Tokens {
  Tokens._();

  // =====================================================================
  // Colour
  // =====================================================================

  /// App background.
  static const Color canvas = Color(0xFFFCF9F0);

  /// Cards, sheets, anything raised off the canvas.
  static const Color surface = Color(0xFFFFFFFF);

  /// Inset wells, viewfinder placeholder, disabled fills.
  static const Color surfaceInset = Color(0xFFF1EDE1);

  /// Every border, every divider, every shadow.
  static const Color outline = Color(0xFF000000);

  /// Primary text.
  static const Color textPrimary = Color(0xFF000000);

  /// Secondary text and metadata.
  static const Color textSecondary = Color(0xFF6B6B6B);

  /// Primary action — shutter, confirm.
  static const Color accent = Color(0xFFFFD84D);

  /// Pressed state for [accent].
  static const Color accentPressed = Color(0xFFE8C22F);

  // ---- State. Reserved for state; never used as category identity. ----

  /// Verified, authentic, signature valid.
  static const Color statusOk = Color(0xFF5EE9A0);

  /// Tampered, denied, destructive, degraded GPS.
  static const Color statusAlert = Color(0xFFFF7BA0);

  /// Caution, fallback key, unavailable service.
  static const Color statusWarn = Color(0xFFF5E3B0);

  // ---- Category identity. Never used to signal state. -----------------

  static const Color tintInfo = Color(0xFFA78BFA);
  static const Color tintCool = Color(0xFFC8E85A);

  /// Unsorted, empty, nothing yet.
  static const Color tintNull = Color(0xFFC4C4C4);

  // =====================================================================
  // Type
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
    color: textPrimary,
    height: 1.1,
  );

  /// 22 / 700 / UI / -0.01em.
  static const TextStyle screenTitle = TextStyle(
    fontFamily: fontUi,
    fontVariations: _wBold,
    fontWeight: FontWeight.w700,
    fontSize: 22,
    letterSpacing: -0.22,
    color: textPrimary,
    height: 1.2,
  );

  /// 15 / 700 / UI.
  static const TextStyle cardTitle = TextStyle(
    fontFamily: fontUi,
    fontVariations: _wBold,
    fontWeight: FontWeight.w700,
    fontSize: 15,
    color: textPrimary,
    height: 1.25,
  );

  /// 15 / 400 / UI. Prose only.
  static const TextStyle body = TextStyle(
    fontFamily: fontUi,
    fontVariations: _wRegular,
    fontWeight: FontWeight.w400,
    fontSize: 15,
    color: textPrimary,
    height: 1.45,
  );

  /// 12 / 500 / UI / 0.02em.
  static const TextStyle label = TextStyle(
    fontFamily: fontUi,
    fontVariations: _wMedium,
    fontWeight: FontWeight.w500,
    fontSize: 12,
    letterSpacing: 0.24,
    color: textSecondary,
  );

  /// 12 / 400 / Data.
  ///
  /// Every number a user might verify goes in this face — a coordinate in a
  /// proportional font instantly looks untrustworthy.
  static const TextStyle data = TextStyle(
    fontFamily: fontData,
    fontSize: 12,
    color: textPrimary,
    height: 1.4,
  );

  /// 11 / 400 / Data. The stamp card's coordinate and time lines.
  static const TextStyle dataStamp = TextStyle(
    fontFamily: fontData,
    fontSize: 11,
    color: textSecondary,
    height: 1.4,
  );

  /// 10 / 400 / Data / 0.06em. Always rendered uppercase.
  static const TextStyle dataSmall = TextStyle(
    fontFamily: fontData,
    fontSize: 10,
    letterSpacing: 0.6,
    color: textSecondary,
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

  static const BorderSide sideOutline =
      BorderSide(color: outline, width: borderWidth);

  /// Hard offset shadow — zero blur, never coloured, never soft. The only
  /// depth cue in the system.
  static const double shadowOffset = 4;

  static const List<BoxShadow> shadow = <BoxShadow>[
    BoxShadow(
      color: outline,
      offset: Offset(shadowOffset, shadowOffset),
      blurRadius: 0,
    ),
  ];

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

  /// Status mark / numbered check bullet.
  static const double markSize = 24;

  /// Fixed label column in a [DataLine], so values align down the page.
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
  // Theme
  // =====================================================================

  static ThemeData theme() {
    const ColorScheme scheme = ColorScheme.light(
      primary: accent,
      onPrimary: textPrimary,
      secondary: statusOk,
      surface: surface,
      onSurface: textPrimary,
      error: statusAlert,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      fontFamily: fontUi,
      splashFactory: InkRipple.splashFactory,
      dividerColor: outline,
      appBarTheme: const AppBarTheme(
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: screenTitle,
        iconTheme: IconThemeData(color: textPrimary),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: textPrimary,
        contentTextStyle: TextStyle(
          fontFamily: fontUi,
          fontSize: 15,
          color: canvas,
        ),
        shape: RoundedRectangleBorder(borderRadius: brControl),
      ),
      textTheme: const TextTheme(
        bodyMedium: body,
        bodySmall: label,
        titleMedium: screenTitle,
      ),
    );
  }
}
