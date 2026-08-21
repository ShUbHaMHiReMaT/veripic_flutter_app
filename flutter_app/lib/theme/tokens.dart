import 'package:flutter/material.dart';

/// The token layer — the only place in the codebase where a raw colour, size,
/// font name, radius, or duration is allowed to appear.
///
/// Names describe the *role* a value plays, never what it looks like, so a
/// palette change never invalidates a name. Derived from `CLAUDE.md`; do not
/// add a token that the design system does not sanction.
class Tokens {
  Tokens._();

  // =====================================================================
  // Colour
  // =====================================================================

  /// App background.
  static const Color background = Color(0xFFF0EDE4);

  /// Inset areas, viewfinder placeholder, disabled fills.
  static const Color surfaceInset = Color(0xFFE2DDCE);

  /// Cards that sit above the background.
  static const Color surfaceRaised = Color(0xFFFFFFFF);

  /// Hairline borders and dividers.
  static const Color borderHairline = Color(0xFFC7C0AE);

  /// Primary text.
  static const Color textPrimary = Color(0xFF1E2A22);

  /// Secondary text and all metadata.
  static const Color textSecondary = Color(0xFF5A6B5F);

  /// Text and icons drawn on top of [actionPrimary].
  static const Color textOnAction = Color(0xFFFFFFFF);

  /// Primary actions, shutter, active state.
  static const Color actionPrimary = Color(0xFF2F5D45);

  /// Pressed state for [actionPrimary].
  static const Color actionPrimaryPressed = Color(0xFF1F3E2E);

  /// Live/recording, degraded GPS, destructive confirm.
  ///
  /// The only saturated colour in the system, and it means *pay attention*.
  /// Never use it for decoration, branding, or a happy state. If two things on
  /// a screen are this colour, one of them is wrong.
  static const Color statusAlert = Color(0xFFE07A2F);

  // =====================================================================
  // Type
  // =====================================================================

  /// Display and UI face. Weights 400 and 500 only.
  static const String fontUi = 'SpaceGrotesk';

  /// Data face. Weight 400 only.
  static const String fontData = 'JetBrainsMono';

  // Space Grotesk ships as a variable font; weight rides the `wght` axis.
  static const List<FontVariation> _wRegular = <FontVariation>[
    FontVariation('wght', 400)
  ];
  static const List<FontVariation> _wMedium = <FontVariation>[
    FontVariation('wght', 500)
  ];

  /// 22 / 500 / UI / -0.01em.
  static const TextStyle screenTitle = TextStyle(
    fontFamily: fontUi,
    fontVariations: _wMedium,
    fontWeight: FontWeight.w500,
    fontSize: 22,
    letterSpacing: -0.22,
    color: textPrimary,
    height: 1.2,
  );

  /// 13 / 500 / UI / 0.06em. Always rendered uppercase.
  static const TextStyle sectionHead = TextStyle(
    fontFamily: fontUi,
    fontVariations: _wMedium,
    fontWeight: FontWeight.w500,
    fontSize: 13,
    letterSpacing: 0.78,
    color: textSecondary,
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

  /// 11 / 400 / Data. Reserved for the stamp card's coordinate and time lines,
  /// which `CLAUDE.md` specifies at 11px.
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

  /// Cards, inputs, and buttons. Never above 8.
  static const double radiusControl = 6;

  /// Full-bleed panels sit flush.
  static const double radiusFlush = 0;

  static const BorderRadius brControl =
      BorderRadius.all(Radius.circular(radiusControl));

  static const double borderWidthHairline = 1;

  /// Left accent bars.
  static const double borderWidthAccent = 3;

  static const BorderSide sideHairline =
      BorderSide(color: borderHairline, width: borderWidthHairline);

  // Spacing scale: 4, 8, 12, 16, 24, 32. Nothing between.
  static const double spaceHair = 4;
  static const double spaceTight = 8;
  static const double spaceSnug = 12;
  static const double spaceBase = 16;
  static const double spaceSection = 24;
  static const double spaceScreen = 32;

  /// Minimum touch target. Field users wear gloves.
  static const double touchMin = 48;

  /// Square control face (shutter, icon buttons). Sits inside [touchMin].
  static const double controlSize = 44;

  /// Log-row and control-row thumbnail.
  static const double thumbSize = 56;

  /// Status mark / small inline icon box.
  static const double markSize = 24;

  /// Fixed label column in a [DataLine], so values align down the page.
  static const double labelColumnWidth = 104;

  /// Upper bound for pinch-zoom on a reviewed frame.
  static const double zoomMaxScale = 5;

  static const double iconSmall = 14;
  static const double iconBase = 20;

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
      MediaQuery.maybeDisableAnimationsOf(context) ?? false
          ? Duration.zero
          : d;

  // =====================================================================
  // Theme
  // =====================================================================

  static ThemeData theme() {
    const ColorScheme scheme = ColorScheme.light(
      primary: actionPrimary,
      onPrimary: textOnAction,
      secondary: statusAlert,
      surface: surfaceRaised,
      onSurface: textPrimary,
      error: statusAlert,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      fontFamily: fontUi,
      splashFactory: InkRipple.splashFactory,
      dividerColor: borderHairline,
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
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
          color: background,
        ),
        shape: RoundedRectangleBorder(borderRadius: brControl),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: actionPrimary,
          foregroundColor: textOnAction,
          disabledBackgroundColor: surfaceInset,
          disabledForegroundColor: textSecondary,
          elevation: 0,
          minimumSize: const Size(0, touchMin),
          padding: const EdgeInsets.symmetric(
              horizontal: spaceSection, vertical: spaceSnug),
          shape: const RoundedRectangleBorder(borderRadius: brControl),
          textStyle: const TextStyle(
            fontFamily: fontUi,
            fontVariations: _wMedium,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: actionPrimary,
          side: sideHairline,
          minimumSize: const Size(0, touchMin),
          padding: const EdgeInsets.symmetric(
              horizontal: spaceSection, vertical: spaceSnug),
          shape: const RoundedRectangleBorder(borderRadius: brControl),
          textStyle: const TextStyle(
            fontFamily: fontUi,
            fontVariations: _wMedium,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: body,
        bodySmall: label,
        titleMedium: screenTitle,
      ),
    );
  }
}
