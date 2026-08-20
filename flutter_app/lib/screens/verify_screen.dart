import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../services/nvidia_vision_service.dart';
import '../services/security_service.dart';
import '../services/verification_service.dart';
import '../theme/veripic_theme.dart';

class VerifyScreen extends StatefulWidget {
  const VerifyScreen({super.key});

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  final VerificationService _service = VerificationService();
  final ImagePicker _picker = ImagePicker();

  bool _busy = false;
  Uint8List? _preview;
  VerificationReport? _report;

  /// Live state of each forensic stage, rendered as the animated checklist.
  final Map<VerifyStage, _StageInfo> _stages = <VerifyStage, _StageInfo>{
    for (final VerifyStage s in VerifyStage.values)
      s: const _StageInfo(StageState.pending, null),
  };

  /// Progress updates are queued and drained on a fixed cadence so the
  /// checklist stays readable — the underlying pipeline resolves the first two
  /// stages in single-digit milliseconds.
  final List<_Update> _queue = <_Update>[];
  bool _draining = false;

  void _resetStages() {
    for (final VerifyStage s in VerifyStage.values) {
      _stages[s] = const _StageInfo(StageState.pending, null);
    }
    _queue.clear();
  }

  void _enqueue(VerifyStage stage, StageState state, String? detail) {
    _queue.add(_Update(stage, state, detail));
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    while (_queue.isNotEmpty) {
      final _Update u = _queue.removeAt(0);
      if (!mounted) break;
      setState(() => _stages[u.stage] = _StageInfo(u.state, u.detail));
      if (u.state != StageState.running) HapticFeedback.selectionClick();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    _draining = false;
  }

  Future<void> _pick(ImageSource source) async {
    final XFile? file = await _picker.pickImage(source: source);
    if (file == null) return;

    HapticFeedback.mediumImpact();
    final Uint8List bytes = await File(file.path).readAsBytes();
    if (!mounted) return;

    setState(() {
      _busy = true;
      _report = null;
      _preview = bytes;
      _resetStages();
    });

    final VerificationReport report =
        await _service.verify(bytes, onProgress: _enqueue);

    // Let the checklist finish playing out before revealing the verdict.
    while (mounted && (_queue.isNotEmpty || _draining)) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    if (!mounted) return;

    HapticFeedback.heavyImpact();
    setState(() {
      _report = report;
      _busy = false;
    });
  }

  Future<void> _chooseSource() async {
    HapticFeedback.selectionClick();
    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: GlassPanel(
            padding: const EdgeInsets.symmetric(vertical: 8),
            tint: VP.surfaceHigh,
            opacity: 0.92,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _SourceTile(
                  icon: Icons.photo_library_rounded,
                  title: 'Gallery',
                  subtitle: 'Analyze an existing image',
                  onTap: () => Navigator.pop(context, ImageSource.gallery),
                ),
                const Divider(color: VP.hairline, height: 1),
                _SourceTile(
                  icon: Icons.photo_camera_rounded,
                  title: 'Camera',
                  subtitle: 'Shoot a frame to analyze now',
                  onTap: () => Navigator.pop(context, ImageSource.camera),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (source != null) await _pick(source);
  }

  @override
  Widget build(BuildContext context) {
    final VerificationReport? report = _report;

    return Scaffold(
      body: ForensicBackdrop(
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                      color: VP.textPrimary,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text('Forensic Analysis',
                              style: TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w700,
                                  color: VP.textPrimary)),
                          Text('4-stage integrity pipeline',
                              style: VP.eyebrow.copyWith(letterSpacing: 1.1)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
                  children: <Widget>[
                    _EvidencePane(
                      preview: _preview,
                      report: report,
                      busy: _busy,
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _chooseSource,
                        icon: Icon(
                            _busy
                                ? Icons.hourglass_top_rounded
                                : Icons.upload_file_rounded,
                            size: 19),
                        label: Text(_busy
                            ? 'Analyzing…'
                            : _preview == null
                                ? 'Select evidence image'
                                : 'Analyze another image'),
                      ),
                    ),
                    if (_preview != null) ...<Widget>[
                      const SizedBox(height: 18),
                      _DiagnosticChecklist(stages: _stages),
                    ],
                    if (report != null) ...<Widget>[
                      const SizedBox(height: 18),
                      _VerdictCard(report: report),
                      if (report.envelope != null) ...<Widget>[
                        const SizedBox(height: 14),
                        _IntegrityMetrics(report: report),
                        const SizedBox(height: 14),
                        _MetadataDrawer(report: report),
                      ],
                      if (report.aiAnalysis != null) ...<Widget>[
                        const SizedBox(height: 14),
                        _AiCard(analysis: report.aiAnalysis!),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Update {
  const _Update(this.stage, this.state, this.detail);
  final VerifyStage stage;
  final StageState state;
  final String? detail;
}

class _StageInfo {
  const _StageInfo(this.state, this.detail);
  final StageState state;
  final String? detail;
}

// =======================================================================
// Evidence pane
// =======================================================================

class _EvidencePane extends StatelessWidget {
  const _EvidencePane({
    required this.preview,
    required this.report,
    required this.busy,
  });

  final Uint8List? preview;
  final VerificationReport? report;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final Color edge = report == null
        ? VP.hairline
        : _verdictColor(report!.verdict).withValues(alpha: 0.55);

    if (preview == null) {
      return GlassPanel(
        padding: const EdgeInsets.symmetric(vertical: 46, horizontal: 20),
        child: Column(
          children: <Widget>[
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: VP.info.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: VP.info.withValues(alpha: 0.25)),
              ),
              child: const Icon(Icons.document_scanner_rounded,
                  color: VP.info, size: 29),
            ),
            const SizedBox(height: 16),
            Text('No evidence loaded', style: VP.title.copyWith(fontSize: 15)),
            const SizedBox(height: 6),
            const Text(
              'Load a photo to recover its embedded envelope, re-derive the '
              'hardware HMAC and measure perceptual drift.',
              textAlign: TextAlign.center,
              style: VP.body,
            ),
          ],
        ),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      decoration: BoxDecoration(
        borderRadius: VP.br,
        border: Border.all(color: edge, width: 1.4),
        boxShadow: report == null
            ? null
            : VP.glow(_verdictColor(report!.verdict), strength: 0.6),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(VP.radius - 1),
        child: Stack(
          children: <Widget>[
            Image.memory(preview!,
                width: double.infinity,
                fit: BoxFit.cover,
                gaplessPlayback: true),
            if (busy)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.45),
                  child: const _AnalyzingOverlay(),
                ),
              ),
            if (report != null && !busy)
              Positioned(
                left: 10,
                top: 10,
                child: StatusChip(
                  label: _verdictLabel(report!.verdict),
                  color: _verdictColor(report!.verdict),
                  icon: _verdictIcon(report!.verdict),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AnalyzingOverlay extends StatefulWidget {
  const _AnalyzingOverlay();

  @override
  State<_AnalyzingOverlay> createState() => _AnalyzingOverlayState();
}

class _AnalyzingOverlayState extends State<_AnalyzingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, _) => CustomPaint(
        painter: _SweepPainter(_c.value),
        child: Center(
          child: Text('SCANNING', style: VP.eyebrow.copyWith(color: VP.accent)),
        ),
      ),
    );
  }
}

class _SweepPainter extends CustomPainter {
  _SweepPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final double y = size.height * t;
    canvas.drawRect(
      Rect.fromLTWH(0, y - 40, size.width, 80),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.transparent,
            VP.accent.withValues(alpha: 0.25),
            Colors.transparent,
          ],
        ).createShader(Rect.fromLTWH(0, y - 40, size.width, 80)),
    );
    canvas.drawLine(Offset(0, y), Offset(size.width, y),
        Paint()..color = VP.accent.withValues(alpha: 0.8));
  }

  @override
  bool shouldRepaint(covariant _SweepPainter old) => old.t != t;
}

// =======================================================================
// Animated diagnostic checklist
// =======================================================================

class _DiagnosticChecklist extends StatelessWidget {
  const _DiagnosticChecklist({required this.stages});

  final Map<VerifyStage, _StageInfo> stages;

  @override
  Widget build(BuildContext context) {
    const List<VerifyStage> all = VerifyStage.values;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.terminal_rounded, size: 15, color: VP.textFaint),
              SizedBox(width: 7),
              Text('DIAGNOSTIC SCAN', style: VP.eyebrow),
            ],
          ),
          const SizedBox(height: 14),
          for (int i = 0; i < all.length; i++)
            _StageRow(
              index: i + 1,
              stage: all[i],
              info: stages[all[i]] ?? const _StageInfo(StageState.pending, null),
              isLast: i == all.length - 1,
            ),
        ],
      ),
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({
    required this.index,
    required this.stage,
    required this.info,
    required this.isLast,
  });

  final int index;
  final VerifyStage stage;
  final _StageInfo info;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final Color color = _stageColor(info.state);
    final bool dim = info.state == StageState.pending;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Column(
            children: <Widget>[
              _StageBullet(state: info.state, index: index),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 1.5,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: dim ? VP.hairline : color.withValues(alpha: 0.35),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 16, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 250),
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: info.state == StageState.running
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: dim ? VP.textFaint : VP.textPrimary,
                          ),
                          child: Text(stage.title),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(stage.code,
                          style: VP.eyebrow.copyWith(
                              fontSize: 9,
                              color: dim ? VP.textFaint : color)),
                    ],
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    alignment: Alignment.topLeft,
                    child: info.detail == null
                        ? const SizedBox(width: double.infinity)
                        : Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              info.detail!,
                              style: VP.monoSmall.copyWith(
                                fontSize: 10.5,
                                color: color.withValues(alpha: 0.9),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StageBullet extends StatelessWidget {
  const _StageBullet({required this.state, required this.index});

  final StageState state;
  final int index;

  @override
  Widget build(BuildContext context) {
    final Color color = _stageColor(state);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: state == StageState.pending
            ? Colors.transparent
            : color.withValues(alpha: 0.14),
        border: Border.all(
          color: state == StageState.pending ? VP.hairline : color,
          width: 1.4,
        ),
        boxShadow: state == StageState.running
            ? VP.glow(color, strength: 0.5)
            : null,
      ),
      child: Center(child: _icon(color)),
    );
  }

  Widget _icon(Color color) {
    switch (state) {
      case StageState.running:
        return SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
        );
      case StageState.passed:
        return Icon(Icons.check_rounded, size: 15, color: color);
      case StageState.failed:
        return Icon(Icons.close_rounded, size: 15, color: color);
      case StageState.warned:
        return Icon(Icons.priority_high_rounded, size: 15, color: color);
      case StageState.skipped:
        return Icon(Icons.remove_rounded, size: 15, color: color);
      case StageState.pending:
        return Text('$index',
            style: const TextStyle(
                fontSize: 11, color: VP.textFaint, fontWeight: FontWeight.w700));
    }
  }
}

// =======================================================================
// Verdict + metrics
// =======================================================================

class _VerdictCard extends StatelessWidget {
  const _VerdictCard({required this.report});
  final VerificationReport report;

  @override
  Widget build(BuildContext context) {
    final Color color = _verdictColor(report.verdict);

    return GlassPanel(
      borderColor: color.withValues(alpha: 0.42),
      glowColor: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _ConfidenceRing(
                value: report.confidence,
                color: color,
                icon: _verdictIcon(report.verdict),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(_verdictLabel(report.verdict),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: color,
                          letterSpacing: -0.2,
                        )),
                    const SizedBox(height: 4),
                    Text('Integrity confidence',
                        style: VP.eyebrow.copyWith(fontSize: 9.5)),
                    const SizedBox(height: 2),
                    Text('${(report.confidence * 100).toStringAsFixed(1)}%',
                        style: VP.monoSmall.copyWith(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: VP.textPrimary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.18)),
            ),
            child: Text(report.reason,
                style: VP.body.copyWith(color: VP.textPrimary, fontSize: 13)),
          ),
          if (report.signatureCheck?.note != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  report.signatureCheck!.origin ==
                          SigningKeyOrigin.hardwareDerived
                      ? Icons.memory_rounded
                      : Icons.history_rounded,
                  size: 14,
                  color: VP.textFaint,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(report.signatureCheck!.note!,
                      style: VP.body.copyWith(fontSize: 11.5)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ConfidenceRing extends StatelessWidget {
  const _ConfidenceRing({
    required this.value,
    required this.color,
    required this.icon,
  });

  final double value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double v, _) => SizedBox(
        width: 72,
        height: 72,
        child: CustomPaint(
          painter: _RingPainter(v, color),
          child: Center(child: Icon(icon, color: color, size: 26)),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color);
  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final Rect arc = rect.deflate(5);

    canvas.drawArc(
      arc,
      0,
      2 * math.pi,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5,
    );

    canvas.drawArc(
      arc,
      -math.pi / 2,
      2 * math.pi * value,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 5,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.value != value || old.color != color;
}

class _IntegrityMetrics extends StatelessWidget {
  const _IntegrityMetrics({required this.report});
  final VerificationReport report;

  @override
  Widget build(BuildContext context) {
    const int threshold = SecurityService.maxPerceptualHammingDistance;
    final int d = report.hammingDistance;
    final bool over = d > threshold;
    final Color color = over ? VP.danger : VP.accent;

    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.grid_on_rounded, size: 15, color: VP.textFaint),
              const SizedBox(width: 7),
              const Text('PERCEPTUAL DRIFT', style: VP.eyebrow),
              const Spacer(),
              Text('$d / 64 bits',
                  style: VP.monoSmall.copyWith(color: color, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 12),
          _HammingBar(distance: d, threshold: threshold, color: color),
          const SizedBox(height: 8),
          Text(
            over
                ? 'Banner gradients diverge beyond the $threshold-bit JPEG '
                    'tolerance — the stamp has been re-rendered or edited.'
                : 'Within the $threshold-bit tolerance reserved for JPEG '
                    'recompression. The banner is pixel-faithful to capture.',
            style: VP.body.copyWith(fontSize: 11.5),
          ),
          const Divider(color: VP.hairline, height: 24),
          DataRow2(
            label: 'Signed dHash',
            value: report.envelope?.pixelHash ?? '—',
            labelWidth: 108,
          ),
          DataRow2(
            label: 'Recomputed',
            value: report.recomputedHash ?? '—',
            valueColor: over ? VP.danger : VP.accent,
            labelWidth: 108,
          ),
        ],
      ),
    );
  }
}

class _HammingBar extends StatelessWidget {
  const _HammingBar({
    required this.distance,
    required this.threshold,
    required this.color,
  });

  final int distance;
  final int threshold;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth;
        return SizedBox(
          height: 22,
          child: Stack(
            children: <Widget>[
              Positioned(
                top: 6,
                left: 0,
                right: 0,
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Positioned(
                top: 6,
                left: 0,
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(
                      begin: 0, end: (distance / 64).clamp(0.02, 1.0)),
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.easeOutCubic,
                  builder: (BuildContext context, double v, _) => Container(
                    height: 8,
                    width: w * v,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: <Color>[
                        color.withValues(alpha: 0.55),
                        color,
                      ]),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: VP.glow(color, strength: 0.5),
                    ),
                  ),
                ),
              ),
              // Threshold marker.
              Positioned(
                left: (w * threshold / 64).clamp(0.0, w - 1),
                top: 0,
                child: Column(
                  children: <Widget>[
                    Container(width: 1.5, height: 20, color: VP.warn),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// =======================================================================
// Metadata drawer
// =======================================================================

class _MetadataDrawer extends StatefulWidget {
  const _MetadataDrawer({required this.report});
  final VerificationReport report;

  @override
  State<_MetadataDrawer> createState() => _MetadataDrawerState();
}

class _MetadataDrawerState extends State<_MetadataDrawer> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final SignedEnvelope e = widget.report.envelope!;
    final DateTime ts =
        DateTime.fromMillisecondsSinceEpoch(e.timestampMs, isUtc: true);
    final DateFormat fmt = DateFormat('yyyy-MM-dd HH:mm:ss');

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _open = !_open);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.data_object_rounded,
                      size: 15, color: VP.textFaint),
                  const SizedBox(width: 7),
                  const Text('EMBEDDED ENVELOPE', style: VP.eyebrow),
                  const SizedBox(width: 8),
                  StatusChip(
                    label: 'v${e.version}',
                    color: e.isHardwareBound ? VP.accent : VP.textSecondary,
                    dense: true,
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: const Icon(Icons.expand_more_rounded,
                        color: VP.textSecondary, size: 20),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 240),
            crossFadeState:
                _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Divider(color: VP.hairline, height: 1),
                  const SizedBox(height: 8),
                  DataRow2(label: 'Latitude', value: e.lat.toStringAsFixed(6)),
                  DataRow2(label: 'Longitude', value: e.lon.toStringAsFixed(6)),
                  DataRow2(
                      label: 'Altitude',
                      value: '${e.alt.toStringAsFixed(1)} m'),
                  DataRow2(
                      label: 'Captured', value: '${fmt.format(ts)} UTC'),
                  DataRow2(label: 'Device hash', value: e.deviceId),
                  DataRow2(label: 'Key id', value: e.kid ?? 'n/a (legacy v3)'),
                  DataRow2(
                    label: 'Key origin',
                    value: widget.report.signatureCheck?.origin?.label ??
                        'unverified',
                  ),
                  DataRow2(label: 'Banner dHash', value: e.pixelHash),
                  DataRow2(label: 'HMAC-SHA256', value: e.signature),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =======================================================================
// NVIDIA analysis
// =======================================================================

class _AiCard extends StatelessWidget {
  const _AiCard({required this.analysis});
  final NvidiaAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final double? score = analysis.syntheticScore;
    final bool unavailable = analysis.error != null;
    final Color color = unavailable
        ? VP.textSecondary
        : (score ?? 0) > 0.5
            ? VP.danger
            : VP.accent;

    return GlassPanel(
      borderColor: color.withValues(alpha: 0.22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.auto_awesome_rounded,
                  size: 15, color: VP.textFaint),
              const SizedBox(width: 7),
              const Text('NVIDIA MULTIMODAL CHECK', style: VP.eyebrow),
              const Spacer(),
              StatusChip(
                label: unavailable ? 'OFFLINE' : 'ONLINE',
                color: unavailable ? VP.warn : VP.accent,
                dense: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (unavailable)
            Text(
              '${analysis.error}\n\nThe cryptographic verdict above is '
              'independent of this check and remains authoritative.',
              style: VP.body.copyWith(fontSize: 12),
            )
          else ...<Widget>[
            Row(
              children: <Widget>[
                Text('Synthetic likelihood',
                    style: VP.body.copyWith(fontSize: 12.5)),
                const Spacer(),
                Text(
                  score == null
                      ? 'n/a'
                      : '${(score * 100).toStringAsFixed(1)}%',
                  style: VP.monoSmall.copyWith(
                      fontSize: 15, fontWeight: FontWeight.w700, color: color),
                ),
              ],
            ),
            if (score != null) ...<Widget>[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: score.clamp(0.0, 1.0)),
                  duration: const Duration(milliseconds: 800),
                  builder: (BuildContext context, double v, _) =>
                      LinearProgressIndicator(
                    value: v,
                    minHeight: 7,
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              ),
            ],
            if (analysis.summary != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(analysis.summary!, style: VP.body.copyWith(fontSize: 12)),
            ],
          ],
        ],
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: VP.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, color: VP.accent, size: 20),
      ),
      title: Text(title, style: VP.title.copyWith(fontSize: 15)),
      subtitle: Text(subtitle, style: VP.body.copyWith(fontSize: 12)),
    );
  }
}

// =======================================================================
// Shared verdict mapping
// =======================================================================

Color _verdictColor(VerificationVerdict v) => switch (v) {
      VerificationVerdict.authentic => VP.accent,
      VerificationVerdict.tamperedPixels => VP.danger,
      VerificationVerdict.tamperedMetadata => VP.danger,
      VerificationVerdict.notSigned => VP.warn,
      VerificationVerdict.error => VP.textSecondary,
    };

IconData _verdictIcon(VerificationVerdict v) => switch (v) {
      VerificationVerdict.authentic => Icons.verified_rounded,
      VerificationVerdict.tamperedPixels => Icons.broken_image_rounded,
      VerificationVerdict.tamperedMetadata => Icons.gpp_bad_rounded,
      VerificationVerdict.notSigned => Icons.help_outline_rounded,
      VerificationVerdict.error => Icons.error_outline_rounded,
    };

String _verdictLabel(VerificationVerdict v) => switch (v) {
      VerificationVerdict.authentic => 'AUTHENTIC & VERIFIED',
      VerificationVerdict.tamperedPixels => 'TAMPERED · PIXELS ALTERED',
      VerificationVerdict.tamperedMetadata => 'TAMPERED · METADATA ALTERED',
      VerificationVerdict.notSigned => 'UNSIGNED',
      VerificationVerdict.error => 'ANALYSIS ERROR',
    };

Color _stageColor(StageState s) => switch (s) {
      StageState.pending => VP.textFaint,
      StageState.running => VP.info,
      StageState.passed => VP.accent,
      StageState.failed => VP.danger,
      StageState.warned => VP.warn,
      StageState.skipped => VP.textSecondary,
    };
