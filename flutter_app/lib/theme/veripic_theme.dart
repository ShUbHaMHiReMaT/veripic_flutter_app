import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Design tokens and reusable chrome for VeriPic's "cyber forensics" look.
///
/// Deep OLED ground, neon emerald accents, crimson alerts, frosted glass.
class VP {
  VP._();

  // ---- Palette -------------------------------------------------------
  static const Color bg = Color(0xFF0A0E17);
  static const Color surface = Color(0xFF111726);
  static const Color surfaceHigh = Color(0xFF18202F);
  static const Color accent = Color(0xFF00E696);
  static const Color accentDim = Color(0xFF0B8F63);
  static const Color danger = Color(0xFFFF3B30);
  static const Color warn = Color(0xFFFFB020);
  static const Color info = Color(0xFF3B9EFF);

  static const Color textPrimary = Color(0xFFEAF2F5);
  static const Color textSecondary = Color(0xFF8E9BB3);
  static const Color textFaint = Color(0xFF56617A);
  static const Color hairline = Color(0x1AFFFFFF);

  // ---- Type ----------------------------------------------------------
  static const String mono = 'monospace';

  static const TextStyle display = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.8,
    color: textPrimary,
    height: 1.05,
  );

  static const TextStyle title = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    color: textPrimary,
    letterSpacing: -0.2,
  );

  static const TextStyle body = TextStyle(
    fontSize: 13.5,
    color: textSecondary,
    height: 1.4,
  );

  /// Small uppercase tracking-wide label used for section headers / codes.
  static const TextStyle eyebrow = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.6,
    color: textFaint,
  );

  static const TextStyle monoSmall = TextStyle(
    fontFamily: mono,
    fontSize: 11.5,
    color: textPrimary,
    height: 1.35,
  );

  // ---- Shape ---------------------------------------------------------
  static const double radius = 18;
  static const BorderRadius br = BorderRadius.all(Radius.circular(radius));

  /// Soft neon halo used behind active elements.
  static List<BoxShadow> glow(Color c, {double strength = 1}) => <BoxShadow>[
        BoxShadow(
          color: c.withValues(alpha: 0.28 * strength),
          blurRadius: 26 * strength,
          spreadRadius: -4,
        ),
      ];

  static ThemeData theme() {
    const ColorScheme scheme = ColorScheme.dark(
      primary: accent,
      onPrimary: Color(0xFF00110B),
      secondary: info,
      surface: surface,
      onSurface: textPrimary,
      error: danger,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: textPrimary,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surfaceHigh,
        contentTextStyle: const TextStyle(color: textPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: const Color(0xFF00110B),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: textPrimary),
        bodySmall: TextStyle(color: textSecondary),
      ),
    );
  }
}

/// Frosted-glass container — the primary surface treatment across the app.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.borderRadius = VP.br,
    this.blur = 18,
    this.tint,
    this.borderColor,
    this.glowColor,
    this.opacity = 0.55,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final double blur;
  final Color? tint;
  final Color? borderColor;
  final Color? glowColor;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final Color base = tint ?? VP.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: glowColor == null ? null : VP.glow(glowColor!, strength: 0.7),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  base.withValues(alpha: opacity + 0.12),
                  base.withValues(alpha: opacity - 0.08),
                ],
              ),
              border: Border.all(
                color: borderColor ?? VP.hairline,
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Small pill label, e.g. `HMAC-SHA256` or a live status chip.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    this.color = VP.accent,
    this.icon,
    this.dense = false,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: dense ? 11 : 13, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: dense ? 10 : 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// Slow-drifting grid + radial bloom used as the app-wide backdrop.
///
/// Deliberately cheap: one repainting [CustomPainter] driven by a single
/// looping controller, no per-frame allocations beyond the paint objects.
class ForensicBackdrop extends StatefulWidget {
  const ForensicBackdrop({
    super.key,
    required this.child,
    this.accent = VP.accent,
    this.animate = true,
  });

  final Widget child;
  final Color accent;
  final bool animate;

  @override
  State<ForensicBackdrop> createState() => _ForensicBackdropState();
}

class _ForensicBackdropState extends State<ForensicBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant ForensicBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.animate && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (BuildContext context, _) => CustomPaint(
                painter: _BackdropPainter(_c.value, widget.accent),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter(this.t, this.accent);

  final double t;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = VP.bg);

    // Ambient bloom that drifts on a slow Lissajous path.
    final Offset c1 = Offset(
      size.width * (0.2 + 0.25 * math.sin(t * 2 * math.pi)),
      size.height * (0.12 + 0.08 * math.cos(t * 2 * math.pi)),
    );
    canvas.drawCircle(
      c1,
      size.width * 0.7,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[accent.withValues(alpha: 0.10), Colors.transparent],
        ).createShader(Rect.fromCircle(center: c1, radius: size.width * 0.7)),
    );

    final Offset c2 = Offset(
      size.width * (0.85 - 0.15 * math.cos(t * 2 * math.pi)),
      size.height * (0.82 + 0.06 * math.sin(t * 2 * math.pi)),
    );
    canvas.drawCircle(
      c2,
      size.width * 0.6,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[VP.info.withValues(alpha: 0.07), Colors.transparent],
        ).createShader(Rect.fromCircle(center: c2, radius: size.width * 0.6)),
    );

    // Fine survey grid.
    final Paint grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.028)
      ..strokeWidth = 1;
    const double step = 34;
    final double offset = (t * step) % step;
    for (double x = -step + offset; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = -step + offset; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
  }

  @override
  bool shouldRepaint(covariant _BackdropPainter old) =>
      old.t != t || old.accent != accent;
}

/// Label/value row with tap-to-copy, used throughout the metadata drawers.
class DataRow2 extends StatefulWidget {
  const DataRow2({
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
  State<DataRow2> createState() => _DataRow2State();
}

class _DataRow2State extends State<DataRow2> {
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
            child: Text(
              widget.label,
              style: const TextStyle(color: VP.textFaint, fontSize: 12),
            ),
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
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Icon(
                  _copied ? Icons.check_rounded : Icons.copy_rounded,
                  size: 14,
                  color: _copied ? VP.accent : VP.textFaint,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
