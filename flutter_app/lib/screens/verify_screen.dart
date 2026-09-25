import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import 'package:printing/printing.dart';

import '../services/account_service.dart';
import '../services/certificate_service.dart';
import '../services/identity_service.dart';
import '../services/security_service.dart';
import '../services/verification_service.dart';
import '../theme/veripic_theme.dart';
import 'paywall.dart';
import 'senders_screen.dart';

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

      // Tell the account a check happened. Verdict only — the photo and its
      // coordinates never leave the phone. Fire and forget: an analytics
      // write must not be able to break a verification.
      unawaited(AccountService().reportCheck(report.verdict.name));
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.vibrate();
      setState(() {
        _busy = false;
        _failure = 'That photo could not be opened. Pick a different one.';
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

    // Pro covers the PDF as well as the check. Asked again here because a
    // Pro month can run out while this screen is open.
    if (!await Paywall.requirePro(context)) return;
    if (!mounted) return;
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
            'geoguard_report_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.vibrate();
      setState(() => _failure =
          'The report could not be made. $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Puts a name to the key that signed this photo.
  ///
  /// Trust on first use: the photo already proves it is unedited, and naming
  /// the sender is the separate, deliberate step that turns "some GeoGuard
  /// phone" into "Ravi" for every photo they send afterwards.
  Future<void> _saveSender() async {
    final String? publicKey = _report?.signatureCheck?.signerPublicKey;
    final Uint8List? bytes = _preview;
    if (publicKey == null || bytes == null) return;

    final TrustedContact? saved =
        await promptSaveSender(context, publicKeyB64: publicKey);
    if (saved == null || !mounted) return;

    // Re-run the check so the verdict now names them. No progress callback:
    // the checklist has already played out.
    final VerificationReport report = await _service.verify(bytes);
    if (mounted) setState(() => _report = report);
  }

  Future<void> _chooseSource() async {
    HapticFeedback.selectionClick();

    // Checking a photo is a Pro feature.
    if (!await Paywall.requirePro(context)) return;
    if (!mounted) return;

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
              const SectionHead(title: 'Pick a photo'),
              const SizedBox(height: Tokens.spaceBase),
              ActionButton(
                label: 'Pick from gallery',
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
      appBar: AppBar(title: const Text('Check a photo')),
      body: idle
          ? EmptyState(
              icon: Icons.fact_check_outlined,
              title: 'No photo picked yet',
              message: 'Pick a photo and GeoGuard will read the details hidden '
                  'inside it, check the signature, check the stamp, and check '
                  'the picture for edits.',
              actionLabel: 'Pick a photo',
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
                    actionLabel: 'Pick a photo',
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
                  if (report.signatureCheck?.isPortable ?? false) ...<Widget>[
                    const SizedBox(height: Tokens.spaceSnug),
                    _SignerCard(
                      check: report.signatureCheck!,
                      onSave: _saveSender,
                    ),
                  ],
                  const SizedBox(height: Tokens.spaceSection),
                ],
                if (preview != null) ...<Widget>[
                  const SectionHead(title: 'Checks'),
                  const SizedBox(height: Tokens.spaceSnug),
                  _CheckList(stages: _stages),
                ],
                if (report != null) ...<Widget>[
                  const SizedBox(height: Tokens.spaceSection),
                  const SectionHead(title: 'What we found'),
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
                        ? 'Making the report'
                        : 'Share a PDF report',
                    icon: Icons.picture_as_pdf_outlined,
                    color: Tokens.tintInfo,
                    onPressed: _exporting ? null : _exportCertificate,
                  ),
                ],
                const SizedBox(height: Tokens.spaceSnug),
                ActionButton(
                  label: _busy ? 'Checking' : 'Check another photo',
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
        headline = 'Real photo';
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
        headline = 'Details changed';
      case VerificationVerdict.notSigned:
        tint = Tokens.statusWarn;
        icon = Icons.help_outline;
        headline = 'Not taken with GeoGuard';
      case VerificationVerdict.error:
        tint = Tokens.statusWarn;
        icon = Icons.error_outline;
        headline = 'Check not finished';
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
                label: report.isAuthentic ? 'real' : 'not real',
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
// Who signed it
// =======================================================================

/// Answers "who took this", which is a different question from "has it been
/// edited" and is kept in its own card so the two are never confused.
///
/// A valid signature is pure maths and means the same on every phone. Knowing
/// *whose* key it is depends entirely on whether this user has saved that key,
/// so an unsaved sender is reported as unknown rather than quietly trusted.
class _SignerCard extends StatelessWidget {
  const _SignerCard({required this.check, required this.onSave});

  final SignatureCheck check;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    final (Color tint, IconData icon) = switch (check.trust) {
      SignerTrust.thisPhone => (Tokens.statusOk, Icons.smartphone_outlined),
      SignerTrust.savedContact => (Tokens.statusOk, Icons.person_outline),
      SignerTrust.unknownPhone => (Tokens.statusWarn, Icons.person_off_outlined),
      SignerTrust.localOnly => (Tokens.tintNull, Icons.smartphone_outlined),
    };

    return FieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconTile(icon: icon, color: tint),
              const SizedBox(width: Tokens.spaceSnug),
              Expanded(child: Text('Who took it', style: p.cardTitle)),
              StatusBadge(
                label: check.trust == SignerTrust.unknownPhone
                    ? 'not saved'
                    : 'known',
                color: tint,
              ),
            ],
          ),
          const SizedBox(height: Tokens.spaceBase),
          Text(check.signerLabel, style: p.screenTitle),
          if (check.note != null) ...<Widget>[
            const SizedBox(height: Tokens.spaceTight),
            Text(check.note!, style: p.body),
          ],
          const SizedBox(height: Tokens.spaceSnug),
          DataLine(
            label: 'Their code',
            value: TrustedContact(
              fingerprint:
                  IdentityService.fingerprintOf(check.signerPublicKey!),
              name: '',
              publicKey: check.signerPublicKey!,
              savedAtMs: 0,
            ).readableFingerprint,
          ),
          if (check.trust == SignerTrust.unknownPhone) ...<Widget>[
            const SizedBox(height: Tokens.spaceSnug),
            ActionButton(
              label: 'Save this sender',
              icon: Icons.person_add_alt,
              onPressed: onSave,
            ),
          ],
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
              Expanded(child: Text('Stamp check', style: p.cardTitle)),
              StatusBadge(
                label: within ? 'unchanged' : 'changed',
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
          Text('$d OF 64 SPOTS DIFFER — LIMIT $threshold', style: p.dataSmall),
          if (check != null) ...<Widget>[
            const SizedBox(height: Tokens.spaceSnug),
            DataLine(
              label: 'Signature',
              value: check.valid ? 'MATCHES' : 'DOES NOT MATCH',
              copyable: false,
            ),
            if (check.matchedKey != null)
              DataLine(
                label: 'Checked with',
                value: check.matchedKey!.origin.plainLabel,
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
              Expanded(child: Text('Picture check', style: p.cardTitle)),
              StatusBadge(
                label: !checked
                    ? 'not checked'
                    : (clean ? 'unchanged' : '$altered changed'),
                color: tint,
              ),
            ],
          ),
          const SizedBox(height: Tokens.spaceSnug),
          if (!checked)
            Text(
              'This photo was taken before picture protection existed, so only '
              'the stamp was protected. The picture itself cannot be checked.',
              style: p.body,
            )
          else ...<Widget>[
            // One square per tile, in the grid they were hashed in.
            _TileGrid(tiles: tiles),
            const SizedBox(height: Tokens.spaceTight),
            Text(
              '${tiles.length - altered} OF ${tiles.length} PARTS MATCH — '
              'LIMIT ${SecurityService.maxSceneTileHammingDistance}',
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
                  '${tiles[i]}',
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
              Expanded(child: Text('All the details', style: p.cardTitle)),
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
                    label: 'GPS location',
                    value: '${e.lat.toStringAsFixed(6)}, '
                        '${e.lon.toStringAsFixed(6)}',
                  ),
                  DataLine(
                    label: 'Height',
                    value: '${e.alt.toStringAsFixed(1)} m',
                  ),
                  DataLine(
                    label: 'Taken on',
                    value:
                        '${DateFormat('ddMMMyy HH:mm:ss').format(captured).toUpperCase()} UTC',
                  ),
                  DataLine(label: 'Phone', value: e.deviceId),
                  DataLine(label: 'Security key', value: e.kid ?? '—'),
                  DataLine(label: 'Format version', value: 'v${e.version}'),
                  DataLine(label: 'Saved stamp code', value: e.pixelHash),
                  if (widget.report.recomputedHash != null)
                    DataLine(
                      label: 'Stamp code now',
                      value: widget.report.recomputedHash!,
                    ),
                  DataLine(label: 'Signature', value: e.signature),
                ],
              ),
            ),
          ),
          const SizedBox(height: Tokens.spaceSnug),
          ActionButton(
            label: _open ? 'Hide details' : 'Show details',
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
            const SectionHead(title: 'Report details'),
            const SizedBox(height: Tokens.spaceSnug),
            Text(
              'These say who is confirming this photo. Leave a box empty and '
              'the report prints a blank line to fill in by hand.',
              style: p.body,
            ),
            const SizedBox(height: Tokens.spaceBase),
            _Field(controller: _name, label: 'Full name'),
            _Field(controller: _designation, label: 'Job title'),
            _Field(controller: _address, label: 'Address'),
            _Field(controller: _reference, label: 'Case or file number'),
            const SizedBox(height: Tokens.spaceBase),
            ActionButton(
              label: 'Make the report',
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
