import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Field kit design system.
///
/// The app is an instrument, not a social camera: legible in sunlight,
/// data-forward, no decoration that isn't information.
///
/// Do not introduce new colors, radii, or fonts here. If a component seems to
/// need one, the component is wrong.
class VP {
  VP._();

  // ---- Color ----------------------------------------------------------
  static const Color sand = Color(0xFFF0EDE4);
  static const Color sandDeep = Color(0xFFE2DDCE);
  static const Color rule = Color(0xFFC7C0AE);
  static const Color ink = Color(0xFF1E2A22);
  static const Color inkSoft = Color(0xFF5A6B5F);
  static const Color forest = Color(0xFF2F5D45);
  static const Color forestDeep = Color(0xFF1F3E2E);
  static const Color signal = Color(0xFFE07A2F);
  static const Color paper = Color(0xFFFFFFFF);

  // ---- Type -----------------------------------------------------------
  static const String grotesk = 'SpaceGrotesk';
  static const String mono = 'JetBrainsMono';

  // Space Grotesk is a variable font; weight comes from the `wght` axis.
  static const List<FontVariation> w400 = <FontVariation>[
    FontVariation('wght', 400)
  ];
  static const List<FontVariation> w500 = <FontVariation>[
    FontVariation('wght', 500)
  ];

  /// 22 / 500 / Grotesk / -0.01em
  static const TextStyle screenTitle = TextStyle(
    fontFamily: grotesk,
    fontVariations: w500,
    fontWeight: FontWeight.w500,
    fontSize: 22,
    letterSpacing: -0.22,
    color: ink,
    height: 1.2,
  );

  /// 13 / 500 / Grotesk / 0.06em / uppercase — apply [upper] at the use site.
  static const TextStyle sectionHead = TextStyle(
    fontFamily: grotesk,
    fontVariations: w500,
    fontWeight: FontWeight.w500,
    fontSize: 13,
    letterSpacing: 0.78,
    color: inkSoft,
  );

  /// 15 / 400 / Grotesk
  static const TextStyle body = TextStyle(
    fontFamily: grotesk,
    fontVariations: w400,
    fontWeight: FontWeight.w400,
    fontSize: 15,
    color: ink,
    height: 1.45,
  );

  /// 12 / 500 / Grotesk / 0.02em
  static const TextStyle label = TextStyle(
    fontFamily: grotesk,
    fontVariations: w500,
    fontWeight: FontWeight.w500,
    fontSize: 12,
    letterSpacing: 0.24,
    color: inkSoft,
  );

  /// 12 / 400 / Mono — every number a user might verify.
  static const TextStyle data = TextStyle(
    fontFamily: mono,
    fontSize: 12,
    color: ink,
    height: 1.4,
  );

  /// 10 / 400 / Mono / 0.06em / uppercase
  static const TextStyle dataSmall = TextStyle(
    fontFamily: mono,
    fontSize: 10,
    letterSpacing: 0.6,
    color: inkSoft,
  );

  // ---- Geometry -------------------------------------------------------
  /// Cards, inputs, buttons. Never above 8.
  static const double radius = 6;
  static const BorderRadius br = BorderRadius.all(Radius.circular(radius));

  /// Spacing scale: 4, 8, 12, 16, 24, 32. Nothing between.
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s24 = 24;
  static const double s32 = 32;

  /// Field users wear gloves.
  static const double minTouch = 48;

  static const BorderSide hairline = BorderSide(color: rule);

  static ThemeData theme() {
    const ColorScheme scheme = ColorScheme.light(
      primary: forest,
      onPrimary: paper,
      secondary: signal,
      surface: paper,
      onSurface: ink,
      error: signal,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: sand,
      fontFamily: grotesk,
      splashFactory: InkRipple.splashFactory,
      dividerColor: rule,
      appBarTheme: const AppBarTheme(
        backgroundColor: sand,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: screenTitle,
        iconTheme: IconThemeData(color: ink),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: ink,
        contentTextStyle: TextStyle(
          fontFamily: grotesk,
          fontSize: 15,
          color: sand,
        ),
        shape: RoundedRectangleBorder(borderRadius: br),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: forest,
          foregroundColor: paper,
          disabledBackgroundColor: sandDeep,
          disabledForegroundColor: inkSoft,
          elevation: 0,
          minimumSize: const Size(0, minTouch),
          padding: const EdgeInsets.symmetric(horizontal: s24, vertical: s12),
          shape: const RoundedRectangleBorder(borderRadius: br),
          textStyle: const TextStyle(
            fontFamily: grotesk,
            fontVariations: w500,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: forest,
          side: hairline,
          minimumSize: const Size(0, minTouch),
          padding: const EdgeInsets.symmetric(horizontal: s24, vertical: s12),
          shape: const RoundedRectangleBorder(borderRadius: br),
          textStyle: const TextStyle(
            fontFamily: grotesk,
            fontVariations: w500,
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

/// Card that sits above sand: paper fill, hairline border, radius 6.
class FieldCard extends StatelessWidget {
  const FieldCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(VP.s16),
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? VP.paper,
        borderRadius: VP.br,
        border: Border.all(color: VP.rule),
      ),
      child: child,
    );
  }
}

/// Left accent bar panel: `border-left: 3px`, radius 0, no other border.
class AccentPanel extends StatelessWidget {
  const AccentPanel({
    super.key,
    required this.child,
    this.accent = VP.forest,
    this.background = VP.paper,
    this.padding = const EdgeInsets.all(VP.s12),
  });

  final Widget child;
  final Color accent;
  final Color background;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: child,
    );
  }
}

/// Uppercase section head over a hairline rule.
class SectionHead extends StatelessWidget {
  const SectionHead({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(title.toUpperCase(), style: VP.sectionHead),
            ),
            if (trailing != null) trailing!,
          ],
        ),
        const SizedBox(height: VP.s8),
        const Divider(height: 1, thickness: 1, color: VP.rule),
      ],
    );
  }
}

/// Label + mono value row with tap-to-copy.
///
/// Every number a user might verify goes in mono — a coordinate in a
/// proportional font instantly looks untrustworthy.
class DataLine extends StatefulWidget {
  const DataLine({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.copyable = true,
    this.labelWidth = 104,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool copyable;
  final double labelWidth;

  @override
  State<DataLine> createState() => _DataLineState();
}

class _DataLineState extends State<DataLine> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    if (!mounted) return;
    HapticFeedback.selectionClick();
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VP.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: widget.labelWidth,
            child: Text(widget.label, style: VP.label),
          ),
          Expanded(
            child: SelectableText(
              widget.value,
              style: VP.data.copyWith(color: widget.valueColor),
            ),
          ),
          if (widget.copyable)
            InkWell(
              onTap: _copy,
              borderRadius: VP.br,
              child: Padding(
                padding: const EdgeInsets.all(VP.s4),
                child: Icon(
                  _copied ? Icons.check : Icons.copy_outlined,
                  size: 14,
                  color: _copied ? VP.forest : VP.inkSoft,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Mono uppercase status chip, e.g. `FIX ±4M`.
class StatusText extends StatelessWidget {
  const StatusText({super.key, required this.text, this.color = VP.inkSoft});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(text.toUpperCase(), style: VP.dataSmall.copyWith(color: color));
  }
}

/// Bordered row with a 56dp thumbnail — the log vernacular.
class LogRow extends StatelessWidget {
  const LogRow({
    super.key,
    required this.title,
    required this.lines,
    this.thumbnail,
    this.accent,
    this.onTap,
  });

  final String title;
  final List<String> lines;
  final Widget? thumbnail;
  final Color? accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: VP.paper,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: VP.minTouch),
          padding: const EdgeInsets.all(VP.s12),
          decoration: BoxDecoration(
            border: Border.all(color: VP.rule),
            borderRadius: VP.br,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (thumbnail != null) ...<Widget>[
                ClipRRect(
                  borderRadius: VP.br,
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: VP.sandDeep,
                      border: Border.all(color: VP.rule),
                      borderRadius: VP.br,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: thumbnail,
                  ),
                ),
                const SizedBox(width: VP.s12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title.toUpperCase(),
                      style: VP.label.copyWith(color: VP.ink),
                    ),
                    for (final String l in lines) ...<Widget>[
                      const SizedBox(height: VP.s4),
                      Text(l, style: VP.dataSmall),
                    ],
                  ],
                ),
              ),
              if (accent != null)
                Container(width: 8, height: 8, color: accent),
              if (onTap != null) ...<Widget>[
                const SizedBox(width: VP.s8),
                const Icon(Icons.chevron_right, size: 20, color: VP.inkSoft),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
