import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// VeriPic design tokens.
///
/// Light, flat and quiet: white cards on a soft blue-grey ground, hairline
/// borders instead of shadows, one blue accent, and pastel tints reserved for
/// status. No gradients, no glass, no glow.
class VP {
  VP._();

  // ---- Ground & structure --------------------------------------------
  static const Color bg = Color(0xFFF4F7FB);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE4EAF2);
  static const Color divider = Color(0xFFEDF1F7);

  // ---- Accent ---------------------------------------------------------
  static const Color primary = Color(0xFF1A6BD8);
  static const Color primaryInk = Color(0xFF0B4EA6);
  static const Color primarySoft = Color(0xFFEAF2FD);

  // ---- Status ---------------------------------------------------------
  static const Color success = Color(0xFF0E8A63);
  static const Color successSoft = Color(0xFFE7F7F1);
  static const Color danger = Color(0xFFD92D20);
  static const Color dangerSoft = Color(0xFFFDECEA);
  static const Color warn = Color(0xFFB25E09);
  static const Color warnSoft = Color(0xFFFFF4E6);

  // ---- Neutral tints (the pastel rows) --------------------------------
  static const Color neutralSoft = Color(0xFFF1F4F9);
  static const Color lavenderSoft = Color(0xFFF3EFFB);

  // ---- Ink ------------------------------------------------------------
  static const Color ink = Color(0xFF111A2B);
  static const Color inkMuted = Color(0xFF5B6B84);
  static const Color inkFaint = Color(0xFF8B99AE);

  static const String mono = 'monospace';

  // ---- Type -----------------------------------------------------------
  static const TextStyle h1 = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w700,
    color: ink,
    letterSpacing: -0.4,
    height: 1.15,
  );

  static const TextStyle h2 = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: ink,
    letterSpacing: -0.1,
  );

  static const TextStyle body = TextStyle(
    fontSize: 13.5,
    color: inkMuted,
    height: 1.45,
  );

  static const TextStyle label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: inkFaint,
  );

  static const TextStyle monoSmall = TextStyle(
    fontFamily: mono,
    fontSize: 11.5,
    color: ink,
    height: 1.35,
  );

  static const double radius = 14;
  static const BorderRadius br = BorderRadius.all(Radius.circular(radius));

  static ThemeData theme() {
    const ColorScheme scheme = ColorScheme.light(
      primary: primary,
      onPrimary: Colors.white,
      surface: surface,
      onSurface: ink,
      error: danger,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      splashFactory: InkRipple.splashFactory,
      dividerColor: divider,
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: ink,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: ink),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: ink,
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: ink),
        bodySmall: TextStyle(color: inkMuted),
      ),
    );
  }
}

/// Flat white card — the single container used across the app.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? VP.surface,
        borderRadius: VP.br,
        border: Border.all(color: borderColor ?? VP.border),
      ),
      child: child,
    );
  }
}

/// Icon + title over a hairline rule — the header treatment from the design.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 18, color: VP.primary),
            const SizedBox(width: 9),
            Expanded(child: Text(title, style: VP.h2)),
            if (trailing != null) trailing!,
          ],
        ),
        const SizedBox(height: 10),
        const Divider(height: 1, thickness: 1, color: VP.divider),
      ],
    );
  }
}

/// Tinted list row: leading label, optional supporting line, trailing value.
///
/// This is the core list unit of the design — a flat band of colour with no
/// border, separated from its neighbours by a 1px gap.
class TintTile extends StatelessWidget {
  const TintTile({
    super.key,
    required this.label,
    this.tint = VP.neutralSoft,
    this.value,
    this.supporting,
    this.icon,
    this.iconColor,
    this.onTap,
    this.selected = false,
    this.dense = false,
  });

  final String label;
  final Color tint;
  final String? value;
  final String? supporting;
  final IconData? icon;
  final Color? iconColor;
  final VoidCallback? onTap;

  /// Solid accent treatment, matching the highlighted row in the design.
  final bool selected;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final Color fg = selected ? Colors.white : VP.ink;
    final Color background = selected ? VP.primary : tint;

    return Material(
      color: background,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: dense ? 12 : 15,
          ),
          child: Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon,
                    size: 18,
                    color: selected ? Colors.white : (iconColor ?? VP.primary)),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                    if (supporting != null) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        supporting!,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: selected
                              ? Colors.white.withValues(alpha: 0.85)
                              : VP.inkMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (value != null) ...<Widget>[
                const SizedBox(width: 12),
                Text(
                  value!,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : VP.inkMuted,
                  ),
                ),
              ],
              if (onTap != null && value == null)
                Icon(Icons.chevron_right_rounded,
                    size: 20,
                    color: selected
                        ? Colors.white.withValues(alpha: 0.9)
                        : VP.inkFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// Groups [TintTile]s into one rounded, clipped stack with 1px separators.
class TileGroup extends StatelessWidget {
  const TileGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: VP.br,
      child: Column(
        children: <Widget>[
          for (int i = 0; i < children.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 1),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Small flat status label.
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.color = VP.primary,
    this.background,
    this.icon,
  });

  final String label;
  final Color color;
  final Color? background;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background ?? color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Label/value row with tap-to-copy, used in the metadata drawers.
class KvRow extends StatefulWidget {
  const KvRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.copyable = true,
    this.labelWidth = 118,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool copyable;
  final double labelWidth;

  @override
  State<KvRow> createState() => _KvRowState();
}

class _KvRowState extends State<KvRow> {
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
      padding: const EdgeInsets.symmetric(vertical: 5),
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
              style: VP.monoSmall.copyWith(color: widget.valueColor),
            ),
          ),
          if (widget.copyable)
            InkWell(
              onTap: _copy,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Icon(
                  _copied ? Icons.check_rounded : Icons.copy_rounded,
                  size: 14,
                  color: _copied ? VP.success : VP.inkFaint,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
