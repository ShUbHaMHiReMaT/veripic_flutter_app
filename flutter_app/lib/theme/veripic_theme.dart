import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

export 'tokens.dart';

/// Shared primitives. Every one consumes tokens only — no raw values — and
/// defines its pressed, disabled, and focused states here rather than letting
/// screens retrofit them.

// =======================================================================
// Pressable surface
// =======================================================================

/// An outlined card carrying the system's hard offset shadow.
///
/// When [onTap] is set, pressing drops the shadow and translates the card by
/// [Tokens.pressShift] so the press reads as physical. Honours reduced motion.
class PressCard extends StatefulWidget {
  const PressCard({
    super.key,
    required this.child,
    this.onTap,
    this.color,
    this.borderRadius = Tokens.brCard,
    this.padding = const EdgeInsets.all(Tokens.spaceBase),
    this.shadow = true,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color? color;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final bool shadow;
  final String? semanticLabel;

  @override
  State<PressCard> createState() => _PressCardState();
}

class _PressCardState extends State<PressCard> {
  bool _pressed = false;

  bool get _live => widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final bool down = _pressed && _live;

    final Widget card = AnimatedContainer(
      duration: Tokens.motion(context, Tokens.motionFast),
      transform: Matrix4.translationValues(
        down ? Tokens.pressShift.dx : 0,
        down ? Tokens.pressShift.dy : 0,
        0,
      ),
      padding: widget.padding,
      decoration: BoxDecoration(
        color: widget.color ?? Tokens.surface,
        borderRadius: widget.borderRadius,
        border: Border.all(color: Tokens.outline, width: Tokens.borderWidth),
        boxShadow: widget.shadow && !down ? Tokens.shadow : null,
      ),
      child: widget.child,
    );

    if (!_live) return card;

    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: Focus(
        child: Builder(
          builder: (BuildContext context) {
            final bool focused = Focus.of(context).hasFocus;
            return GestureDetector(
              onTapDown: (_) => setState(() => _pressed = true),
              onTapCancel: () => setState(() => _pressed = false),
              onTapUp: (_) => setState(() => _pressed = false),
              onTap: widget.onTap,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: widget.borderRadius,
                  border: Border.all(
                    color: focused ? Tokens.accent : Colors.transparent,
                    width: Tokens.borderWidth,
                  ),
                ),
                child: card,
              ),
            );
          },
        ),
      ),
    );
  }
}

// =======================================================================
// Icon tile
// =======================================================================

/// Rounded square filled with an identity colour — the anchor of every card.
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    required this.color,
    this.size = Tokens.tileSize,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: Tokens.brControl,
        border: Border.all(color: Tokens.outline, width: Tokens.borderWidth),
      ),
      child: Icon(icon, size: Tokens.iconTile, color: Tokens.textPrimary),
    );
  }
}

// =======================================================================
// Badge
// =======================================================================

/// Full-round outlined pill, mono uppercase. Used for NEW, SEALED, verdicts.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    this.color = Tokens.accent,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.spaceTight,
        vertical: Tokens.spaceHair,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: Tokens.brPill,
        border: Border.all(color: Tokens.outline, width: Tokens.borderWidth),
      ),
      child: Text(
        label.toUpperCase(),
        style: Tokens.dataSmall.copyWith(color: Tokens.textPrimary),
      ),
    );
  }
}

// =======================================================================
// Tab card
// =======================================================================

/// The core unit: a card with a coloured tab protruding from its top-left
/// edge, like a file folder.
class TabCard extends StatelessWidget {
  const TabCard({
    super.key,
    required this.icon,
    required this.tint,
    required this.title,
    this.meta = const <String>[],
    this.badge,
    this.onTap,
  });

  final IconData icon;
  final Color tint;
  final String title;

  /// Mono metadata lines shown top-right, e.g. `57 frames`.
  final List<String> meta;
  final String? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Folder tab, overlapping the card's top border so the two read as
        // one shape.
        Padding(
          padding: const EdgeInsets.only(left: Tokens.spaceSnug),
          child: Container(
            width: Tokens.touchMin,
            height: Tokens.spaceBase,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(Tokens.radiusControl),
              ),
              border: Border.all(
                color: Tokens.outline,
                width: Tokens.borderWidth,
              ),
            ),
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -Tokens.borderWidth),
          child: PressCard(
            onTap: onTap,
            semanticLabel: <String>[title, ...meta].join('. '),
            padding: const EdgeInsets.all(Tokens.spaceSnug),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    IconTile(icon: icon, color: tint),
                    const SizedBox(width: Tokens.spaceTight),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: <Widget>[
                          for (final String m in meta)
                            Text(m, style: Tokens.dataSmall),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Tokens.spaceBase),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        title,
                        style: Tokens.cardTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (badge != null) ...<Widget>[
                      const SizedBox(width: Tokens.spaceHair),
                      StatusBadge(label: badge!, color: Tokens.statusAlert),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// =======================================================================
// Buttons
// =======================================================================

/// Primary action: accent fill, outline, hard shadow, physical press.
class ActionButton extends StatelessWidget {
  const ActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = Tokens.accent,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color color;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;
    final Color ink = enabled ? Tokens.textPrimary : Tokens.textSecondary;

    return PressCard(
      onTap: onPressed,
      color: enabled ? color : Tokens.surfaceInset,
      borderRadius: Tokens.brControl,
      semanticLabel: label,
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.spaceBase,
        vertical: Tokens.spaceSnug,
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: Tokens.iconBase, color: ink),
            const SizedBox(width: Tokens.spaceTight),
          ],
          Text(label, style: Tokens.cardTitle.copyWith(color: ink)),
        ],
      ),
    );
  }
}

/// Square outlined icon control, as in the header row of the design.
class IconButtonTile extends StatelessWidget {
  const IconButtonTile({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.semanticLabel,
    this.color = Tokens.surface,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String semanticLabel;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: Tokens.touchMin,
      height: Tokens.touchMin,
      child: PressCard(
        onTap: onPressed,
        color: color,
        borderRadius: Tokens.brControl,
        semanticLabel: semanticLabel,
        padding: EdgeInsets.zero,
        child: Icon(icon, size: Tokens.iconBase, color: Tokens.textPrimary),
      ),
    );
  }
}

// =======================================================================
// Structure
// =======================================================================

/// Plain bold section heading. No rule, no uppercase.
class SectionHead extends StatelessWidget {
  const SectionHead({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Row(
        children: <Widget>[
          Expanded(child: Text(title, style: Tokens.cardTitle)),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Outlined card with the system shadow. Non-interactive.
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
    return PressCard(padding: padding, color: color, child: child);
  }
}

/// Card with a solid accent bar down its left inside edge.
class AccentPanel extends StatelessWidget {
  const AccentPanel({
    super.key,
    required this.child,
    this.accent = Tokens.accent,
    this.background = Tokens.surface,
    this.padding = const EdgeInsets.all(Tokens.spaceSnug),
  });

  final Widget child;
  final Color accent;
  final Color background;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return PressCard(
      color: background,
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              width: Tokens.spaceSnug,
              decoration: BoxDecoration(
                color: accent,
                border: const Border(right: Tokens.sideOutline),
              ),
            ),
            Expanded(child: Padding(padding: padding, child: child)),
          ],
        ),
      ),
    );
  }
}

/// Outlined pill holding a mono uppercase readout, e.g. `FIX ±4M`.
class StatusText extends StatelessWidget {
  const StatusText({
    super.key,
    required this.text,
    this.color = Tokens.surface,
  });

  final String text;

  /// Fill colour. State colours signal; [Tokens.surface] is the resting look.
  final Color color;

  @override
  Widget build(BuildContext context) {
    return StatusBadge(label: text, color: color);
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
                    color: Tokens.textPrimary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bordered row with a thumbnail or icon tile.
class LogRow extends StatelessWidget {
  const LogRow({
    super.key,
    required this.title,
    required this.lines,
    this.thumbnail,
    this.icon,
    this.tint = Tokens.tintNull,
    this.onTap,
  });

  final String title;
  final List<String> lines;
  final Widget? thumbnail;
  final IconData? icon;
  final Color tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return PressCard(
      onTap: onTap,
      padding: const EdgeInsets.all(Tokens.spaceSnug),
      semanticLabel: <String>[title, ...lines].join('. '),
      child: Row(
        children: <Widget>[
          if (thumbnail != null)
            Container(
              width: Tokens.thumbSize,
              height: Tokens.thumbSize,
              decoration: BoxDecoration(
                color: Tokens.surfaceInset,
                borderRadius: Tokens.brControl,
                border: Border.all(
                  color: Tokens.outline,
                  width: Tokens.borderWidth,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: thumbnail,
            )
          else if (icon != null)
            IconTile(icon: icon!, color: tint),
          const SizedBox(width: Tokens.spaceSnug),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(title, style: Tokens.cardTitle),
                for (final String l in lines) ...<Widget>[
                  const SizedBox(height: Tokens.spaceHair),
                  Text(l, style: Tokens.dataSmall),
                ],
              ],
            ),
          ),
          if (onTap != null)
            const Icon(
              Icons.chevron_right,
              size: Tokens.iconBase,
              color: Tokens.textPrimary,
            ),
        ],
      ),
    );
  }
}

// =======================================================================
// States
// =======================================================================

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Tokens.spaceBase),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          IconTile(icon: icon, color: Tokens.tintNull),
          const SizedBox(height: Tokens.spaceBase),
          Text(title, style: Tokens.screenTitle),
          const SizedBox(height: Tokens.spaceTight),
          Text(message, style: Tokens.body),
          if (actionLabel != null) ...<Widget>[
            const SizedBox(height: Tokens.spaceSection),
            ActionButton(
              label: actionLabel!,
              onPressed: onAction,
              expand: false,
            ),
          ],
        ],
      ),
    );
  }
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: message,
      child: FieldCard(
        child: Row(
          children: <Widget>[
            const SizedBox(
              width: Tokens.iconBase,
              height: Tokens.iconBase,
              child: CircularProgressIndicator(
                strokeWidth: Tokens.borderWidth,
                color: Tokens.textPrimary,
              ),
            ),
            const SizedBox(width: Tokens.spaceSnug),
            Expanded(child: Text(message, style: Tokens.body)),
          ],
        ),
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AccentPanel(
            accent: Tokens.statusAlert,
            child: Text(message, style: Tokens.body),
          ),
          if (actionLabel != null) ...<Widget>[
            const SizedBox(height: Tokens.spaceBase),
            ActionButton(
              label: actionLabel!,
              onPressed: onAction,
              expand: false,
            ),
          ],
        ],
      ),
    );
  }
}
