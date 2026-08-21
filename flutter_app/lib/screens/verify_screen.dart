import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import 'package:printing/printing.dart';

import '../services/certificate_service.dart';
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
  final CertificateService _certificates = CertificateService();
  final ImagePicker _picker = ImagePicker();

  bool _exporting = false;

  bool _busy = false;
  Uint8List? _preview;
  VerificationReport? _report;
  String? _failure;

  /// Live state of each check, rendered as the numbered list.
  final Map<VerifyStage, _StageInfo> _stages = <VerifyStage, _StageInfo>{
    for (final VerifyStage s in VerifyStage.values)
      s: const _StageInfo(StageState.pending, null),
  };

  /// Progress updates are queued and drained on a fixed cadence so the list
  /// stays readable — the pipeline resolves the first two checks in
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
    try {
      final XFile? file = await _picker.pickImage(source: source);
      if (file == null) return;

      HapticFeedback.mediumImpact();
      final Uint8List bytes = await File(file.path).readAsBytes();
      if (!mounted) return;

      setState(() {
        _busy = true;
        _failure = null;
        _report = null;
        _preview = bytes;
        _resetStages();
      });

      final VerificationReport report =
          await _service.verify(bytes, onProgress: _enqueue);

      // Let the list finish playing out before revealing the verdict.
      while (mounted && (_queue.isNotEmpty || _draining)) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      if (!mounted) return;

      HapticFeedback.heavyImpact();
      setState(() {
        _report = report;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.vibrate();
      setState(() {
        _busy = false;
        _failure = 'That frame could not be opened. Pick a different file.';
      });
    }
  }

  /// Collects the details the statute asks for, then renders and shares the
  /// certificate. Returns early if the operator cancels.
  Future<void> _exportCertificate() async {
    final VerificationReport? report = _report;
    final Uint8List? bytes = _preview;
    if (report == null || bytes == null || _exporting) return;

    HapticFeedback.mediumImpact();
    final CertificateParticulars? particulars =
        await showDialog<CertificateParticulars>(
      context: context,
      builder: (_) => const _ParticularsDialog(),
    );
    if (particulars == null || !mounted) return;

    setState(() => _exporting = true);
    try {
      final Uint8List pdf = await _certificates.build(
        report: report,
        imageBytes: bytes,
        particulars: particulars,
      );
      await Printing.sharePdf(
        bytes: pdf,
        filename:
            'geoguard_certificate_\${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.vibrate();
      setState(() => _failure =
          'The certificate could not be generated. \$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _chooseSource() async {
    HapticFeedback.selectionClick();
    final Palette p = Palette.of(context);

    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Tokens.radiusCard),
        ),
        side: p.side,
      ),
      builder: (BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Tokens.spaceBase),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SectionHead(title: 'Select a frame'),
              const SizedBox(height: Tokens.spaceBase),
              ActionButton(
                label: 'Choose from gallery',
                icon: Icons.folder_outlined,
                onPressed: () => Navigator.of(context).pop(ImageSource.gallery),
              ),
              const SizedBox(height: Tokens.spaceSnug),
              ActionButton(
                label: 'Take a photo',
                icon: Icons.photo_camera_outlined,
                color: Tokens.tintInfo,
                onPressed: () => Navigator.of(context).pop(ImageSource.camera),
              ),
            ],
          ),
        ),
      ),
    );

    if (source != null) await _pick(source);
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final VerificationReport? report = _report;
    final Uint8List? preview = _preview;
    final bool idle = preview == null && !_busy && _failure == null;

    return Scaffold(
      appBar: AppBar(title: const Text('Check')),
      body: idle
          ? EmptyState(
              icon: Icons.fact_check_outlined,
              title: 'No frame selected',
              message: 'Pick a frame and GeoGuard will recover its payload, '
                  'validate the signature, measure stamp drift, and screen it '
                  'for AI generation.',
              actionLabel: 'Select a frame',
              onAction: _chooseSource,
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                Tokens.spaceBase,
                Tokens.spaceTight,
                Tokens.spaceBase,
                Tokens.spaceScreen,
              ),
              children: <Widget>[
                if (_failure != null) ...<Widget>[
                  ErrorState(
                    message: _failure!,
                    actionLabel: 'Select a frame',
                    onAction: _chooseSource,
                  ),
                  const SizedBox(height: Tokens.spaceSection),
                ],
                if (preview != null) ...<Widget>[
                  PressCard(
                    padding: const EdgeInsets.all(Tokens.spaceTight),
                    child: ClipRRect(
                      borderRadius: Tokens.brControl,
                      child: ColoredBox(
                        color: p.surfaceInset,
                        child: AspectRatio(
                          aspectRatio: 4 / 3,
                          child: Image.memory(preview, fit: BoxFit.contain),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: Tokens.spaceSection),
                ],
                if (report != null) ...<Widget>[
                  _Verdict(report: report),
                  const SizedBox(height: Tokens.spaceSection),
                ],
                if (preview != null) ...<Widget>[
                  const SectionHead(title: 'Checks'),
                  const SizedBox(height: Tokens.spaceSnug),
                  _CheckList(stages: _stages),
                ],
                if (report != null) ...<Widget>[
                  const SizedBox(height: Tokens.spaceSection),
                  const SectionHead(title: 'Findings'),
                  const SizedBox(height: Tokens.spaceSnug),
                  _DriftCard(report: report),
                  const SizedBox(height: Tokens.spaceSnug),
                  _SceneCard(report: report),
                  if (report.envelope != null) ...<Widget>[
                    const SizedBox(height: Tokens.spaceSnug),
                    _MetadataDrawer(report: report),
                  ],
                ],
                if (report != null) ...<Widget>[
                  const SizedBox(height: Tokens.spaceSection),
                  ActionButton(
                    label: _exporting
                        ? 'Preparing certificate'
                        : 'Export evidence certificate',
                    icon: Icons.picture_as_pdf_outlined,
                    color: Tokens.tintInfo,
                    onPressed: _exporting ? null : _exportCertificate,
                  ),
                ],
                const SizedBox(height: Tokens.spaceSnug),
                ActionButton(
                  label: _busy ? 'Checking' : 'Check another frame',
                  icon: Icons.refresh,
                  onPressed: _busy ? null : _chooseSource,
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
// Check list
// =======================================================================

class _CheckList extends StatelessWidget {
  const _CheckList({required this.stages});

  final Map<VerifyStage, _StageInfo> stages;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        for (int i = 0; i < VerifyStage.values.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: Tokens.spaceTight),
          _StageRow(
            index: i + 1,
            stage: VerifyStage.values[i],
            info: stages[VerifyStage.values[i]]!,
          ),
        ],
      ],
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
    final Palette p = Palette.of(context);

    late final Color tint;
    late final Widget mark;
    switch (info.state) {
      case StageState.pending:
        tint = p.surfaceInset;
        mark = Text('$index', style: p.dataSmall);
      case StageState.running:
        tint = Tokens.accent;
        mark = const SizedBox(
          width: Tokens.iconSmall,
          height: Tokens.iconSmall,
          child: CircularProgressIndicator(
            strokeWidth: Tokens.borderWidth,
            color: Tokens.onIdentity,
          ),
        );
      case StageState.passed:
        tint = Tokens.statusOk;
        mark = const Icon(Icons.check,
            size: Tokens.iconSmall, color: Tokens.onIdentity);
      case StageState.failed:
        tint = Tokens.statusAlert;
        mark = const Icon(Icons.close,
            size: Tokens.iconSmall, color: Tokens.onIdentity);
      case StageState.warned:
        tint = Tokens.statusWarn;
        mark = const Icon(Icons.priority_high,
            size: Tokens.iconSmall, color: Tokens.onIdentity);
      case StageState.skipped:
        tint = Tokens.tintNull;
        mark = const Icon(Icons.remove,
            size: Tokens.iconSmall, color: Tokens.onIdentity);
    }

    return FieldCard(
      padding: const EdgeInsets.all(Tokens.spaceSnug),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: Tokens.markSize,
            height: Tokens.markSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: Tokens.brControl,
              border: Border.all(color: p.outline, width: Tokens.borderWidth),
            ),
            child: mark,
          ),
          const SizedBox(width: Tokens.spaceSnug),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(stage.title, style: p.cardTitle),
                if (info.detail != null) ...<Widget>[
                  const SizedBox(height: Tokens.spaceHair),
                  Text(info.detail!, style: p.dataSmall),
                ],
              ],
            ),
          ),
        ],
      ),
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
    final Palette p = Palette.of(context);

    late final Color tint;
    late final IconData icon;
    late final String headline;

    switch (report.verdict) {
      case VerificationVerdict.authentic:
        tint = Tokens.statusOk;
        icon = Icons.verified_outlined;
        headline = 'Authentic';
      case VerificationVerdict.tamperedScene:
        tint = Tokens.statusAlert;
        icon = Icons.image_not_supported_outlined;
        headline = 'Photo edited';
      case VerificationVerdict.tamperedPixels:
        tint = Tokens.statusAlert;
        icon = Icons.broken_image_outlined;
        headline = 'Stamp edited';
      case VerificationVerdict.tamperedMetadata:
        tint = Tokens.statusAlert;
        icon = Icons.gpp_bad_outlined;
        headline = 'Signature mismatch';
      case VerificationVerdict.notSigned:
        tint = Tokens.statusWarn;
        icon = Icons.help_outline;
        headline = 'Not signed by GeoGuard';
      case VerificationVerdict.error:
        tint = Tokens.statusWarn;
        icon = Icons.error_outline;
        headline = 'Check incomplete';
    }

    return FieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconTile(icon: icon, color: tint),
              const SizedBox(width: Tokens.spaceSnug),
              Expanded(child: Text(headline, style: p.screenTitle)),
              StatusBadge(
                label: report.isAuthentic ? 'authentic' : 'not authentic',
                color: tint,
              ),
            ],
          ),
          const SizedBox(height: Tokens.spaceBase),
          Text(report.reason, style: p.body),
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
    final Palette p = Palette.of(context);

    const int threshold = SecurityService.maxPerceptualHammingDistance;
    final int d = report.hammingDistance;
    final bool within = d <= threshold;
    final Color tint = within ? Tokens.statusOk : Tokens.statusAlert;
    final SignatureCheck? check = report.signatureCheck;

    return FieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('Stamp drift', style: p.cardTitle)),
              StatusBadge(
                label: within ? 'in tolerance' : 'over tolerance',
                color: tint,
              ),
            ],
          ),
          const SizedBox(height: Tokens.spaceSnug),
          // Gauge: filled portion is measured drift.
          Container(
            height: Tokens.spaceSnug,
            decoration: BoxDecoration(
              color: p.surfaceInset,
              borderRadius: Tokens.brPill,
              border: Border.all(color: p.outline, width: Tokens.borderWidth),
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: <Widget>[
                Expanded(
                  flex: d.clamp(0, 64),
                  child: ColoredBox(color: tint),
                ),
                Expanded(flex: 64 - d.clamp(0, 64), child: const SizedBox()),
              ],
            ),
          ),
          const SizedBox(height: Tokens.spaceTight),
          Text('HAMMING $d / 64 — TOLERANCE $threshold', style: p.dataSmall),
          if (check != null) ...<Widget>[
            const SizedBox(height: Tokens.spaceSnug),
            DataLine(
              label: 'Signature',
              value: check.valid ? 'VALID' : 'INVALID',
              copyable: false,
            ),
            if (check.matchedKey != null)
              DataLine(
                label: 'Verified by',
                value: check.matchedKey!.origin.label,
                copyable: false,
              ),
            if (check.note != null) ...<Widget>[
              const SizedBox(height: Tokens.spaceHair),
              Text(check.note!, style: p.body),
            ],
          ],
        ],
      ),
    );
  }
}

// =======================================================================
// Scene integrity
// =======================================================================

class _SceneCard extends StatelessWidget {
  const _SceneCard({required this.report});

  final VerificationReport report;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    final List<int> tiles = report.sceneTileDistances;
    final bool checked = report.sceneWasChecked;
    final int altered = report.alteredTiles;
    final bool clean = checked && altered == 0;

    final Color tint = !checked
        ? Tokens.tintNull
        : (clean ? Tokens.statusOk : Tokens.statusAlert);

    return FieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('Scene integrity', style: p.cardTitle)),
              StatusBadge(
                label: !checked
                    ? 'not covered'
                    : (clean ? 'intact' : '\$altered altered'),
                color: tint,
              ),
            ],
          ),
          const SizedBox(height: Tokens.spaceSnug),
          if (!checked)
            Text(
              'This frame was signed before scene protection existed, so only '
              'its stamp banner was covered. The picture itself cannot be '
              'checked.',
              style: p.body,
            )
          else ...<Widget>[
            // One square per tile, in the grid they were hashed in.
            _TileGrid(tiles: tiles),
            const SizedBox(height: Tokens.spaceTight),
            Text(
              'TILES \${tiles.length - altered}/\${tiles.length} MATCH — '
              'TOLERANCE \${SecurityService.maxSceneTileHammingDistance}',
              style: p.dataSmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// Renders the scene tiles as a grid, so an edit shows up where it happened.
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.tiles});

  final List<int> tiles;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    const int side = SecurityService.sceneGrid;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double cell =
            (c.maxWidth - (side - 1) * Tokens.spaceHair) / side;
        return Wrap(
          spacing: Tokens.spaceHair,
          runSpacing: Tokens.spaceHair,
          children: <Widget>[
            for (int i = 0; i < tiles.length; i++)
              Container(
                width: cell,
                height: cell,
                decoration: BoxDecoration(
                  color: tiles[i] > SecurityService.maxSceneTileHammingDistance
                      ? Tokens.statusAlert
                      : Tokens.statusOk,
                  borderRadius: Tokens.brControl,
                  border:
                      Border.all(color: p.outline, width: Tokens.borderWidth),
                ),
                alignment: Alignment.center,
                child: Text(
                  '\${tiles[i]}',
                  style: Tokens.dataSmall.copyWith(color: Tokens.onIdentity),
                ),
              ),
          ],
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
    final Palette p = Palette.of(context);
    final SignedEnvelope e = widget.report.envelope!;
    final DateTime captured =
        DateTime.fromMillisecondsSinceEpoch(e.timestampMs, isUtc: true);

    return FieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('Embedded metadata', style: p.cardTitle)),
              Icon(
                _open ? Icons.expand_less : Icons.expand_more,
                size: Tokens.iconBase,
                color: p.textPrimary,
              ),
            ],
          ),
          AnimatedCrossFade(
            duration: Tokens.motion(context, Tokens.motionBase),
            crossFadeState:
                _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: Tokens.spaceSnug),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  DataLine(
                    label: 'Coordinates',
                    value: '${e.lat.toStringAsFixed(6)}, '
                        '${e.lon.toStringAsFixed(6)}',
                  ),
                  DataLine(
                    label: 'Altitude',
                    value: '${e.alt.toStringAsFixed(1)} m',
                  ),
                  DataLine(
                    label: 'Captured',
                    value:
                        '${DateFormat('ddMMMyy HH:mm:ss').format(captured).toUpperCase()} UTC',
                  ),
                  DataLine(label: 'Device', value: e.deviceId),
                  DataLine(label: 'Signing key', value: e.kid ?? '—'),
                  DataLine(label: 'Envelope', value: 'v${e.version}'),
                  DataLine(label: 'Stored hash', value: e.pixelHash),
                  if (widget.report.recomputedHash != null)
                    DataLine(
                      label: 'Recomputed',
                      value: widget.report.recomputedHash!,
                    ),
                  DataLine(label: 'Signature', value: e.signature),
                ],
              ),
            ),
          ),
          const SizedBox(height: Tokens.spaceSnug),
          ActionButton(
            label: _open ? 'Hide metadata' : 'Show metadata',
            color: p.surfaceInset,
            expand: false,
            onPressed: () {
              HapticFeedback.selectionClick();
              setState(() => _open = !_open);
            },
          ),
        ],
      ),
    );
  }
}

// =======================================================================
// Certificate particulars
// =======================================================================

/// Collects the facts the statute requires about a person, which the app has
/// no way of knowing. Every field may be left blank — the certificate then
/// prints a ruled line for it to be completed by hand.
class _ParticularsDialog extends StatefulWidget {
  const _ParticularsDialog();

  @override
  State<_ParticularsDialog> createState() => _ParticularsDialogState();
}

class _ParticularsDialogState extends State<_ParticularsDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _designation = TextEditingController();
  final TextEditingController _address = TextEditingController();
  final TextEditingController _reference = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _designation.dispose();
    _address.dispose();
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return Dialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: Tokens.brCard,
        side: p.side,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Tokens.spaceBase),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SectionHead(title: 'Certificate particulars'),
            const SizedBox(height: Tokens.spaceSnug),
            Text(
              'These identify the person certifying the record. Leave any field '
              'blank to print a ruled line instead.',
              style: p.body,
            ),
            const SizedBox(height: Tokens.spaceBase),
            _Field(controller: _name, label: 'Full name'),
            _Field(controller: _designation, label: 'Designation'),
            _Field(controller: _address, label: 'Address'),
            _Field(controller: _reference, label: 'Case or file reference'),
            const SizedBox(height: Tokens.spaceBase),
            ActionButton(
              label: 'Generate certificate',
              icon: Icons.picture_as_pdf_outlined,
              onPressed: () => Navigator.of(context).pop(
                CertificateParticulars(
                  declarantName: _name.text,
                  declarantDesignation: _designation.text,
                  declarantAddress: _address.text,
                  caseReference: _reference.text,
                ),
              ),
            ),
            const SizedBox(height: Tokens.spaceSnug),
            ActionButton(
              label: 'Cancel',
              color: p.surfaceInset,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.spaceSnug),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: p.label),
          const SizedBox(height: Tokens.spaceHair),
          TextField(
            controller: controller,
            style: p.body,
            cursorColor: p.textPrimary,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: p.surfaceInset,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: Tokens.spaceSnug,
                vertical: Tokens.spaceSnug,
              ),
              border: OutlineInputBorder(
                borderRadius: Tokens.brControl,
                borderSide: p.side,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: Tokens.brControl,
                borderSide: p.side,
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: Tokens.brControl,
                borderSide: BorderSide(
                  color: Tokens.accent,
                  width: Tokens.borderWidth,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
