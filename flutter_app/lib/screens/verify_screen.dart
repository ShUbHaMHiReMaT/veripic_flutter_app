import 'dart:async';
import 'dart:io';

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

  /// Live state of each forensic stage, rendered as the checklist.
  final Map<VerifyStage, _StageInfo> _stages = <VerifyStage, _StageInfo>{
    for (final VerifyStage s in VerifyStage.values)
      s: const _StageInfo(StageState.pending, null),
  };

  /// Progress updates are queued and drained on a fixed cadence so the
  /// checklist stays readable — the pipeline resolves the first two stages in
  /// single-digit milliseconds.
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
      await Future<void>.delayed(const Duration(milliseconds: 280));
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
      backgroundColor: VP.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(VP.radius)),
      ),
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: VP.s16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: VP.s16),
              child: Text('SELECT A FRAME', style: VP.sectionHead),
            ),
            const SizedBox(height: VP.s8),
            const Divider(height: 1, color: VP.rule),
            ListTile(
              minVerticalPadding: VP.s12,
              leading: const Icon(Icons.folder_outlined, color: VP.forest),
              title: const Text('Choose from gallery', style: VP.body),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
            const Divider(height: 1, color: VP.rule),
            ListTile(
              minVerticalPadding: VP.s12,
              leading:
                  const Icon(Icons.photo_camera_outlined, color: VP.forest),
              title: const Text('Take a photo', style: VP.body),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
            const SizedBox(height: VP.s8),
          ],
        ),
      ),
    );

    if (source != null) await _pick(source);
  }

  @override
  Widget build(BuildContext context) {
    final VerificationReport? report = _report;
    final Uint8List? preview = _preview;
    final bool idle = preview == null && !_busy;

    return Scaffold(
      appBar: AppBar(title: const Text('Check')),
      body: idle
          ? _EmptyState(onPick: _chooseSource)
          : ListView(
              padding:
                  const EdgeInsets.fromLTRB(VP.s16, VP.s8, VP.s16, VP.s32),
              children: <Widget>[
                if (preview != null) ...<Widget>[
                  Container(
                    decoration:
                        BoxDecoration(border: Border.all(color: VP.rule)),
                    child: ColoredBox(
                      color: VP.sandDeep,
                      child: AspectRatio(
                        aspectRatio: 4 / 3,
                        child: Image.memory(preview, fit: BoxFit.contain),
                      ),
                    ),
                  ),
                  const SizedBox(height: VP.s24),
                ],
                if (report != null) ...<Widget>[
                  _Verdict(report: report),
                  const SizedBox(height: VP.s24),
                ],
                const SectionHead(title: 'Checks'),
                const SizedBox(height: VP.s12),
                _Checklist(stages: _stages),
                if (report != null) ...<Widget>[
                  const SizedBox(height: VP.s24),
                  const SectionHead(title: 'Findings'),
                  const SizedBox(height: VP.s12),
                  _DriftCard(report: report),
                  if (report.aiAnalysis != null) ...<Widget>[
                    const SizedBox(height: VP.s8),
                    _AiCard(analysis: report.aiAnalysis!),
                  ],
                  if (report.envelope != null) ...<Widget>[
                    const SizedBox(height: VP.s8),
                    _MetadataDrawer(report: report),
                  ],
                ],
                const SizedBox(height: VP.s24),
                OutlinedButton(
                  onPressed: _busy ? null : _chooseSource,
                  child: Text(_busy ? 'Checking' : 'Check another frame'),
                ),
              ],
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
// Empty state
// =======================================================================

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPick});

  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(VP.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('No frame selected yet.', style: VP.body),
          const SizedBox(height: VP.s8),
          const Text(
            'Pick an image and VeriPic will recover its payload, validate the '
            'signature, measure stamp drift, and screen it for AI generation.',
            style: VP.body,
          ),
          const SizedBox(height: VP.s24),
          FilledButton(
            onPressed: onPick,
            child: const Text('Select a frame'),
          ),
        ],
      ),
    );
  }
}

// =======================================================================
// Checklist
// =======================================================================

class _Checklist extends StatelessWidget {
  const _Checklist({required this.stages});

  final Map<VerifyStage, _StageInfo> stages;

  @override
  Widget build(BuildContext context) {
    return FieldCard(
      padding: const EdgeInsets.symmetric(horizontal: VP.s12),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < VerifyStage.values.length; i++) ...<Widget>[
            if (i > 0) const Divider(height: 1, color: VP.rule),
            _StageRow(
              index: i + 1,
              stage: VerifyStage.values[i],
              info: stages[VerifyStage.values[i]]!,
            ),
          ],
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
  });

  final int index;
  final VerifyStage stage;
  final _StageInfo info;

  @override
  Widget build(BuildContext context) {
    final bool pending = info.state == StageState.pending;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VP.s12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _StageMark(state: info.state, index: index),
          const SizedBox(width: VP.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  stage.title,
                  style: VP.body.copyWith(
                    fontSize: 14,
                    color: pending ? VP.inkSoft : VP.ink,
                  ),
                ),
                if (info.detail != null) ...<Widget>[
                  const SizedBox(height: VP.s4),
                  Text(info.detail!, style: VP.dataSmall),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Square status mark — instrument vernacular, no circles or ticks-in-bubbles.
class _StageMark extends StatelessWidget {
  const _StageMark({required this.state, required this.index});

  final StageState state;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (state == StageState.running) {
      return const SizedBox(
        width: VP.s24,
        height: VP.s24,
        child: Padding(
          padding: EdgeInsets.all(VP.s4),
          child: CircularProgressIndicator(strokeWidth: 2, color: VP.forest),
        ),
      );
    }

    late final Color color;
    late final Widget mark;
    switch (state) {
      case StageState.pending:
        color = VP.rule;
        mark = Text('$index', style: VP.dataSmall);
      case StageState.passed:
        color = VP.forest;
        mark = const Icon(Icons.check, size: 14, color: VP.forest);
      case StageState.failed:
        color = VP.signal;
        mark = const Icon(Icons.close, size: 14, color: VP.signal);
      case StageState.warned:
        color = VP.signal;
        mark = const Icon(Icons.priority_high, size: 14, color: VP.signal);
      case StageState.skipped:
        color = VP.rule;
        mark = const Icon(Icons.remove, size: 14, color: VP.inkSoft);
      case StageState.running:
        color = VP.rule;
        mark = const SizedBox.shrink();
    }

    return Container(
      width: VP.s24,
      height: VP.s24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: VP.br,
      ),
      child: mark,
    );
  }
}

// =======================================================================
// Verdict
// =======================================================================

class _Verdict extends StatelessWidget {
  const _Verdict({required this.report});

  final VerificationReport report;

  @override
  Widget build(BuildContext context) {
    late final Color accent;
    late final String headline;

    switch (report.verdict) {
      case VerificationVerdict.authentic:
        accent = VP.forest;
        headline = 'AUTHENTIC';
      case VerificationVerdict.tamperedPixels:
        accent = VP.signal;
        headline = 'STAMP EDITED';
      case VerificationVerdict.tamperedMetadata:
        accent = VP.signal;
        headline = 'SIGNATURE MISMATCH';
      case VerificationVerdict.notSigned:
        accent = VP.signal;
        headline = 'NOT SIGNED BY VERIPIC';
      case VerificationVerdict.error:
        accent = VP.signal;
        headline = 'CHECK INCOMPLETE';
    }

    return AccentPanel(
      accent: accent,
      padding: const EdgeInsets.all(VP.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Expanded(
                child: Text(headline,
                    style: VP.screenTitle.copyWith(fontSize: 18)),
              ),
              Text(
                '${(report.confidence * 100).round()}%',
                style: VP.data.copyWith(fontSize: 18, color: accent),
              ),
            ],
          ),
          const SizedBox(height: VP.s4),
          const Text('CONFIDENCE', style: VP.dataSmall),
          const SizedBox(height: VP.s12),
          Text(report.reason, style: VP.body.copyWith(fontSize: 14)),
        ],
      ),
    );
  }
}

// =======================================================================
// Stamp drift
// =======================================================================

class _DriftCard extends StatelessWidget {
  const _DriftCard({required this.report});

  final VerificationReport report;

  @override
  Widget build(BuildContext context) {
    const int threshold = SecurityService.maxPerceptualHammingDistance;
    final int d = report.hammingDistance;
    final bool within = d <= threshold;
    final Color color = within ? VP.forest : VP.signal;
    final SignatureCheck? check = report.signatureCheck;

    return FieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text('STAMP DRIFT',
                    style: VP.label.copyWith(color: VP.ink)),
              ),
              StatusText(
                text: within ? 'WITHIN TOLERANCE' : 'OVER TOLERANCE',
                color: color,
              ),
            ],
          ),
          const SizedBox(height: VP.s12),
          // Bar reads as a gauge: filled portion is measured drift.
          SizedBox(
            height: VP.s8,
            child: Row(
              children: <Widget>[
                Expanded(
                  flex: d.clamp(0, 64),
                  child: ColoredBox(color: color),
                ),
                Expanded(
                  flex: 64 - d.clamp(0, 64),
                  child: const ColoredBox(color: VP.sandDeep),
                ),
              ],
            ),
          ),
          const SizedBox(height: VP.s8),
          Text('HAMMING $d / 64 — TOLERANCE $threshold',
              style: VP.dataSmall),
          if (check != null) ...<Widget>[
            const Divider(height: VP.s24, color: VP.rule),
            DataLine(
              label: 'Signature',
              value: check.valid ? 'VALID' : 'INVALID',
              valueColor: check.valid ? VP.forest : VP.signal,
              copyable: false,
            ),
            if (check.matchedKey != null)
              DataLine(
                label: 'Verified by',
                value: check.matchedKey!.origin.label,
                copyable: false,
              ),
            if (check.note != null) ...<Widget>[
              const SizedBox(height: VP.s4),
              Text(check.note!, style: VP.body.copyWith(fontSize: 13)),
            ],
          ],
        ],
      ),
    );
  }
}

// =======================================================================
// AI screening
// =======================================================================

class _AiCard extends StatelessWidget {
  const _AiCard({required this.analysis});

  final NvidiaAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final double? score = analysis.syntheticScore;
    final bool unavailable = analysis.error != null || score == null;
    final Color color =
        unavailable ? VP.inkSoft : (score > 0.5 ? VP.signal : VP.forest);

    return FieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text('AI SCREENING',
                    style: VP.label.copyWith(color: VP.ink)),
              ),
              StatusText(
                text: unavailable
                    ? 'UNAVAILABLE'
                    : '${(score * 100).round()}% SYNTHETIC',
                color: color,
              ),
            ],
          ),
          const SizedBox(height: VP.s8),
          Text(
            analysis.error ??
                analysis.summary ??
                'The model returned no commentary.',
            style: VP.body.copyWith(fontSize: 13),
          ),
        ],
      ),
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
    final DateTime captured =
        DateTime.fromMillisecondsSinceEpoch(e.timestampMs, isUtc: true);

    return FieldCard(
      padding: const EdgeInsets.symmetric(horizontal: VP.s16),
      child: Column(
        children: <Widget>[
          InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _open = !_open);
            },
            child: Container(
              constraints: const BoxConstraints(minHeight: VP.minTouch),
              alignment: Alignment.centerLeft,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text('EMBEDDED METADATA',
                        style: VP.label.copyWith(color: VP.ink)),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 20, color: VP.inkSoft),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState:
                _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(bottom: VP.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Divider(height: 1, color: VP.rule),
                  const SizedBox(height: VP.s8),
                  DataLine(
                    label: 'Coordinates',
                    value: '${e.lat.toStringAsFixed(6)}, '
                        '${e.lon.toStringAsFixed(6)}',
                  ),
                  DataLine(
                      label: 'Altitude',
                      value: '${e.alt.toStringAsFixed(1)} m'),
                  DataLine(
                    label: 'Captured',
                    value: '${DateFormat('ddMMMyy HH:mm:ss').format(captured).toUpperCase()} UTC',
                  ),
                  DataLine(label: 'Device', value: e.deviceId),
                  DataLine(label: 'Signing key', value: e.kid ?? '—'),
                  DataLine(label: 'Envelope', value: 'v${e.version}'),
                  DataLine(label: 'Stored hash', value: e.pixelHash),
                  if (widget.report.recomputedHash != null)
                    DataLine(
                      label: 'Recomputed',
                      value: widget.report.recomputedHash!,
                      valueColor: widget.report.recomputedHash == e.pixelHash
                          ? VP.forest
                          : VP.signal,
                    ),
                  DataLine(label: 'Signature', value: e.signature),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
