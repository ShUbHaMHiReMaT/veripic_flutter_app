import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

export 'tokens.dart';

// NOTE (Phase 2): these components are the current shared UI surface. They
// consume tokens only — no raw values. They will move into a dedicated
// primitives layer, alongside the button / pill / empty / loading / error
// primitives that do not exist yet.

/// Card that sits above the background: raised fill, hairline border.
class FieldCard extends StatelessWidget {
  const FieldCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Tokens.spaceBase),
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
        color: color ?? Tokens.surfaceRaised,
        borderRadius: Tokens.brControl,
        border: Border.all(
          color: Tokens.borderHairline,
          width: Tokens.borderWidthHairline,
        ),
      ),
      child: child,
    );
  }
}

/// Left accent bar panel: sits flush, no border other than the bar.
class AccentPanel extends StatelessWidget {
  const AccentPanel({
    super.key,
    required this.child,
    this.accent = Tokens.actionPrimary,
    this.background = Tokens.surfaceRaised,
    this.padding = const EdgeInsets.all(Tokens.spaceSnug),
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
        border: Border(
          left: BorderSide(color: accent, width: Tokens.borderWidthAccent),
        ),
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
    return Semantics(
      header: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(title.toUpperCase(), style: Tokens.sectionHead),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: Tokens.spaceTight),
          const Divider(
            height: Tokens.borderWidthHairline,
            thickness: Tokens.borderWidthHairline,
            color: Tokens.borderHairline,
          ),
        ],
      ),
    );
  }
}

/// Label plus a monospace value, with tap-to-copy.
class DataLine extends StatefulWidget {
  const DataLine({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.copyable = true,
    this.labelWidth = Tokens.labelColumnWidth,
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
      padding: const EdgeInsets.symmetric(vertical: Tokens.spaceHair),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: widget.labelWidth,
            child: Text(widget.label, style: Tokens.label),
          ),
          Expanded(
            child: SelectableText(
              widget.value,
              style: Tokens.data.copyWith(color: widget.valueColor),
            ),
          ),
          if (widget.copyable)
            Semantics(
              button: true,
              label: 'Copy ${widget.label}',
              child: InkWell(
                onTap: _copy,
                borderRadius: Tokens.brControl,
                child: Padding(
                  padding: const EdgeInsets.all(Tokens.spaceHair),
                  child: Icon(
                    _copied ? Icons.check : Icons.copy_outlined,
                    size: Tokens.iconSmall,
                    color:
                        _copied ? Tokens.actionPrimary : Tokens.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Monospace uppercase status readout, e.g. `FIX ±4M`.
class StatusText extends StatelessWidget {
  const StatusText({
    super.key,
    required this.text,
    this.color = Tokens.textSecondary,
  });

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: Tokens.dataSmall.copyWith(color: color),
    );
  }
}

/// Bordered row with a thumbnail — the log vernacular.
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
    return Semantics(
      button: onTap != null,
      label: <String>[title, ...lines].join('. '),
      excludeSemantics: true,
      child: Material(
        color: Tokens.surfaceRaised,
        borderRadius: Tokens.brControl,
        child: InkWell(
          onTap: onTap,
          borderRadius: Tokens.brControl,
          child: Container(
            constraints: const BoxConstraints(minHeight: Tokens.touchMin),
            padding: const EdgeInsets.all(Tokens.spaceSnug),
            decoration: BoxDecoration(
              border: Border.all(
                color: Tokens.borderHairline,
                width: Tokens.borderWidthHairline,
              ),
              borderRadius: Tokens.brControl,
            ),
            child: Row(
              children: <Widget>[
                if (thumbnail != null) ...<Widget>[
                  Container(
                    width: Tokens.thumbSize,
                    height: Tokens.thumbSize,
                    decoration: BoxDecoration(
                      color: Tokens.surfaceInset,
                      border: Border.all(
                        color: Tokens.borderHairline,
                        width: Tokens.borderWidthHairline,
                      ),
                      borderRadius: Tokens.brControl,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: thumbnail,
                  ),
                  const SizedBox(width: Tokens.spaceSnug),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        title.toUpperCase(),
                        style: Tokens.label
                            .copyWith(color: Tokens.textPrimary),
                      ),
                      for (final String l in lines) ...<Widget>[
                        const SizedBox(height: Tokens.spaceHair),
                        Text(l, style: Tokens.dataSmall),
                      ],
                    ],
                  ),
                ),
                if (accent != null)
                  Container(
                    width: Tokens.spaceTight,
                    height: Tokens.spaceTight,
                    color: accent,
                  ),
                if (onTap != null) ...<Widget>[
                  const SizedBox(width: Tokens.spaceTight),
                  const Icon(
                    Icons.chevron_right,
                    size: Tokens.iconBase,
                    color: Tokens.textSecondary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
