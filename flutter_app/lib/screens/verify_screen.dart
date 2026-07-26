import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../services/security_service.dart';
import '../services/verification_service.dart';

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

  Future<void> _pick() async {
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    setState(() {
      _busy = true;
      _report = null;
    });
    final Uint8List bytes = await File(file.path).readAsBytes();
    final VerificationReport report = await _service.verify(bytes);
    if (!mounted) return;
    setState(() {
      _preview = bytes;
      _report = report;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify Photo')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_preview != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.memory(_preview!, fit: BoxFit.cover),
              )
            else
              Container(
                height: 200,
                decoration: BoxDecoration(
                  color: const Color(0xFF121A22),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                child: const Center(
                  child: Text('Pick an image to verify',
                      style: TextStyle(color: Colors.white54)),
                ),
              ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.folder_open),
              label: Text(_busy ? 'Analyzing…' : 'Choose image'),
            ),
            const SizedBox(height: 24),
            if (_report != null) _ReportView(report: _report!),
          ],
        ),
      ),
    );
  }
}

class _ReportView extends StatelessWidget {
  const _ReportView({required this.report});
  final VerificationReport report;

  @override
  Widget build(BuildContext context) {
    final _Badge b = _badgeFor(report.verdict);
    final SignedEnvelope? env = report.envelope;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: b.color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: b.color.withOpacity(0.5)),
          ),
          child: Row(
            children: <Widget>[
              Icon(b.icon, color: b.color, size: 34),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(b.title,
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800, color: b.color)),
                    const SizedBox(height: 4),
                    Text(report.reason, style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (env != null) _envelopeCard(env),
        if (report.aiAnalysis != null) ...<Widget>[
          const SizedBox(height: 16),
          _aiCard(report.aiAnalysis!),
        ],
      ],
    );
  }

  Widget _envelopeCard(SignedEnvelope e) {
    final DateTime ts = DateTime.fromMillisecondsSinceEpoch(e.timestampMs, isUtc: true);
    final DateFormat fmt = DateFormat('yyyy-MM-dd HH:mm:ss');
    return _Card(
      title: 'Embedded envelope',
      children: <Widget>[
        _row('Latitude', e.lat.toStringAsFixed(6)),
        _row('Longitude', e.lon.toStringAsFixed(6)),
        _row('Altitude', '${e.alt.toStringAsFixed(1)} m'),
        _row('Timestamp', '${fmt.format(ts)} UTC'),
        _row('Device', e.deviceId),
        _row('Pixel hash', e.pixelHash),
        _row('Signature', e.signature),
      ],
    );
  }

  Widget _aiCard(dynamic ai) {
    final double? score = ai.syntheticScore as double?;
    return _Card(
      title: 'NVIDIA Vision analysis',
      children: <Widget>[
        if (ai.error != null)
          Text(ai.error as String, style: const TextStyle(color: Colors.orangeAccent))
        else ...<Widget>[
          _row('Synthetic score',
              score == null ? 'n/a' : '${(score * 100).toStringAsFixed(1)}%'),
          _row('Summary', (ai.summary as String?) ?? '—'),
        ],
      ],
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
                width: 110,
                child: Text(k, style: const TextStyle(color: Colors.white54, fontSize: 13))),
            Expanded(
              child: SelectableText(v,
                  style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12)),
            ),
          ],
        ),
      );

  _Badge _badgeFor(VerificationVerdict v) {
    switch (v) {
      case VerificationVerdict.authentic:
        return _Badge('AUTHENTIC & VERIFIED', Icons.verified, const Color(0xFF00E5A8));
      case VerificationVerdict.tamperedPixels:
        return _Badge('TAMPERED · PIXELS ALTERED', Icons.broken_image, Colors.redAccent);
      case VerificationVerdict.tamperedMetadata:
        return _Badge('TAMPERED · METADATA ALTERED', Icons.report, Colors.orangeAccent);
      case VerificationVerdict.notSigned:
        return _Badge('UNSIGNED', Icons.help_outline, Colors.amber);
      case VerificationVerdict.error:
        return _Badge('ERROR', Icons.error, Colors.grey);
    }
  }
}

class _Badge {
  const _Badge(this.title, this.icon, this.color);
  final String title;
  final IconData icon;
  final Color color;
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF121A22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(title,
              style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}
