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
      backgroundColor: VP.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 8),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: VP.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: VP.primary),
              title: const Text('Choose from gallery',
                  style: TextStyle(fontSize: 15)),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_camera_outlined, color: VP.primary),
              title:
                  const Text('Take a photo', style: TextStyle(fontSize: 15)),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
            const SizedBox(height: 10),
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
      appBar: AppBar(title: const Text('Verify')),
      body: idle
          ? _EmptyState(onPick: _chooseSource)
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
              children: <Widget>[
                if (preview != null) ...<Widget>[
                  ClipRRect(
                    borderRadius: VP.br,
                    child: ColoredBox(
                      color: Colors.black,
                      child: AspectRatio(
                        aspectRatio: 4 / 3,
                        child:
                            Image.memory(preview, fit: BoxFit.contain),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                if (report != null) ...<Widget>[
                  _VerdictCard(report: report),
                  const SizedBox(height: 22),
                ],
                const SectionHeader(
                    icon: Icons.checklist_rtl_rounded, title: 'Diagnostics'),
                const SizedBox(height: 14),
                _Checklist(stages: _stages),
                if (report != null) ...<Widget>[
                  const SizedBox(height: 22),
                  const SectionHeader(
                      icon: Icons.rule_folder_outlined, title: 'Findings'),
                  const SizedBox(height: 14),
                  _IntegrityCard(report: report),
                  if (report.aiAnalysis != null) ...<Widget>[
                    const SizedBox(height: 12),
                    _AiCard(analysis: report.aiAnalysis!),
                  ],
                  if (report.envelope != null) ...<Widget>[
                    const SizedBox(height: 12),
                    _MetadataDrawer(report: report),
                  ],
                ],
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: _busy ? null : _chooseSource,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: VP.primary,
                    side: const BorderSide(color: VP.border),
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(_busy ? 'Analysing…' : 'Verify another photo',
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: VP.primarySoft,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.fact_check_outlined,
                  size: 30, color: VP.primary),
            ),
            const SizedBox(height: 20),
            const Text('Check a photo', style: VP.h2),
            const SizedBox(height: 8),
            const Text(
              'Pick an image and VeriPic will recover its payload, validate the '
              'signature, compare the stamp, and screen it for AI generation.',
              textAlign: TextAlign.center,
              style: VP.body,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onPick,
              child: const Text('Choose a photo'),
            ),
          ],
        ),
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
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < VerifyStage.values.length; i++) ...<Widget>[
            if (i > 0) const Divider(height: 1, color: VP.divider),
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
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _StageBullet(state: info.state, index: index),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  stage.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: pending ? VP.inkFaint : VP.ink,
                  ),
                ),
                if (info.detail != null) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(info.detail!,
                      style: const TextStyle(
                          fontSize: 12.5, height: 1.35, color: VP.inkMuted)),
                ],
              ],
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
    switch (state) {
      case StageState.running:
        return const SizedBox(
          width: 24,
          height: 24,
          child: Padding(
            padding: EdgeInsets.all(3),
            child: CircularProgressIndicator(
                strokeWidth: 2, color: VP.primary),
          ),
        );
      case StageState.pending:
        return Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: VP.neutralSoft,
            shape: BoxShape.circle,
          ),
          child: Text('$index',
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: VP.inkFaint)),
        );
      case StageState.passed:
        return _icon(Icons.check_rounded, VP.success);
      case StageState.failed:
        return _icon(Icons.close_rounded, VP.danger);
      case StageState.warned:
        return _icon(Icons.priority_high_rounded, VP.warn);
      case StageState.skipped:
        return _icon(Icons.remove_rounded, VP.inkFaint);
    }
  }

  Widget _icon(IconData icon, Color color) => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 15, color: color),
      );
}

// =======================================================================
// Verdict
// =======================================================================

class _VerdictCard extends StatelessWidget {
  const _VerdictCard({required this.report});

  final VerificationReport report;

  @override
  Widget build(BuildContext context) {
    late final Color color;
    late final Color soft;
    late final IconData icon;
    late final String title;

    switch (report.verdict) {
      case VerificationVerdict.authentic:
        color = VP.success;
        soft = VP.successSoft;
        icon = Icons.verified_outlined;
        title = 'Authentic';
      case VerificationVerdict.tamperedPixels:
        color = VP.danger;
        soft = VP.dangerSoft;
        icon = Icons.broken_image_outlined;
        title = 'Stamp edited';
      case VerificationVerdict.tamperedMetadata:
        color = VP.danger;
        soft = VP.dangerSoft;
        icon = Icons.gpp_bad_outlined;
        title = 'Signature mismatch';
      case VerificationVerdict.notSigned:
        color = VP.warn;
        soft = VP.warnSoft;
        icon = Icons.help_outline_rounded;
        title = 'Not signed by VeriPic';
      case VerificationVerdict.error:
        color = VP.warn;
        soft = VP.warnSoft;
        icon = Icons.error_outline_rounded;
        title = 'Could not complete';
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: soft,
        borderRadius: VP.br,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 24, color: color),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: color,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              Text(
                '${(report.confidence * 100).round()}%',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            report.reason,
            style: const TextStyle(
                fontSize: 13, height: 1.45, color: VP.inkMuted),
          ),
        ],
      ),
    );
  }
}

// =======================================================================
// Integrity metrics
// =======================================================================

class _IntegrityCard extends StatelessWidget {
  const _IntegrityCard({required this.report});

  final VerificationReport report;

  @override
  Widget build(BuildContext context) {
    const int threshold = SecurityService.maxPerceptualHammingDistance;
    final int d = report.hammingDistance;
    final bool within = d <= threshold;
    final Color color = within ? VP.success : VP.danger;
    final SignatureCheck? check = report.signatureCheck;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(child: Text('Stamp drift', style: VP.h2)),
              Pill(
                label: within ? 'Within tolerance' : 'Exceeds tolerance',
                color: color,
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (d / 64).clamp(0.0, 1.0),
              minHeight: 7,
              backgroundColor: VP.neutralSoft,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            'Hamming distance $d of 64 · tolerance $threshold',
            style: const TextStyle(fontSize: 12, color: VP.inkMuted),
          ),
          if (check != null) ...<Widget>[
            const Divider(height: 26, color: VP.divider),
            KvRow(
              label: 'Signature',
              value: check.valid ? 'Valid' : 'Invalid',
              valueColor: check.valid ? VP.success : VP.danger,
              copyable: false,
            ),
            if (check.matchedKey != null)
              KvRow(
                  label: 'Verified by',
                  value: check.matchedKey!.origin.label,
                  copyable: false),
            if (check.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(check.note!,
                    style: const TextStyle(
                        fontSize: 12, height: 1.4, color: VP.inkMuted)),
              ),
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
    final Color color = unavailable
        ? VP.inkFaint
        : (score > 0.5 ? VP.warn : VP.success);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(child: Text('AI screening', style: VP.h2)),
              Pill(
                label: unavailable
                    ? 'Unavailable'
                    : '${(score * 100).round()}% synthetic',
                color: color,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            analysis.error ??
                analysis.summary ??
                'The model returned no commentary.',
            style: const TextStyle(
                fontSize: 12.5, height: 1.45, color: VP.inkMuted),
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

    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        children: <Widget>[
          InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _open = !_open);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                children: <Widget>[
                  const Expanded(child: Text('Embedded metadata', style: VP.h2)),
                  Icon(
                    _open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: VP.inkFaint,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState:
                _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Divider(height: 1, color: VP.divider),
                  const SizedBox(height: 8),
                  KvRow(
                    label: 'Coordinates',
                    value: '${e.lat.toStringAsFixed(6)}, '
                        '${e.lon.toStringAsFixed(6)}',
                  ),
                  KvRow(
                      label: 'Altitude',
                      value: '${e.alt.toStringAsFixed(1)} m'),
                  KvRow(
                    label: 'Captured',
                    value:
                        '${DateFormat('yyyy-MM-dd HH:mm:ss').format(captured)} UTC',
                  ),
                  KvRow(label: 'Device', value: e.deviceId),
                  KvRow(label: 'Signing key', value: e.kid ?? '—'),
                  KvRow(label: 'Envelope', value: 'v${e.version}'),
                  KvRow(label: 'Stored hash', value: e.pixelHash),
                  if (widget.report.recomputedHash != null)
                    KvRow(
                      label: 'Recomputed',
                      value: widget.report.recomputedHash!,
                      valueColor: widget.report.recomputedHash == e.pixelHash
                          ? VP.success
                          : VP.danger,
                    ),
                  KvRow(label: 'Signature', value: e.signature),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
