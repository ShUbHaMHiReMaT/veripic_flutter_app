
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../services/frame_store.dart';
import '../services/security_service.dart';
import '../theme/veripic_theme.dart';

/// One stored frame, full size, with the payload that was sealed into it.
class FrameDetailScreen extends StatefulWidget {
  const FrameDetailScreen({super.key, required this.frame});

  final StoredFrame frame;

  @override
  State<FrameDetailScreen> createState() => _FrameDetailScreenState();
}

class _FrameDetailScreenState extends State<FrameDetailScreen> {
  final SecurityService _security = SecurityService();

  late final Future<SignedEnvelope?> _future = _read();

  Future<SignedEnvelope?> _read() async {
    final Uint8List bytes = await widget.frame.file.readAsBytes();
    return _security.extractEnvelope(bytes);
  }

  /// Shares the original file, untouched.
  ///
  /// The proof lives in bytes the photo carries — an EXIF comment, a JPEG COM
  /// segment and a tail block. Chat apps that "send as photo" re-encode and
  /// strip all three, so the receiving app finds nothing to check. Sharing the
  /// file itself is the only thing that survives, which is why the sheet says
  /// so in plain words.
  Future<void> _share() async {
    HapticFeedback.mediumImpact();
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(widget.frame.path, mimeType: 'image/jpeg')],
        subject: 'GeoGuard photo',
        text: 'Send this as a file or document, not as a photo — apps that '
            'squeeze photos strip the proof out of it.',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final String stamp = DateFormat('ddMMMyy HH:mm')
        .format(widget.frame.capturedAt)
        .toUpperCase();

    return Scaffold(
      appBar: AppBar(title: const Text('Photo')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Tokens.spaceBase,
          Tokens.spaceTight,
          Tokens.spaceBase,
          Tokens.spaceScreen,
        ),
        children: <Widget>[
          PressCard(
            padding: const EdgeInsets.all(Tokens.spaceTight),
            child: ClipRRect(
              borderRadius: Tokens.brControl,
              child: ColoredBox(
                color: p.surfaceInset,
                child: InteractiveViewer(
                  maxScale: Tokens.zoomMaxScale,
                  child: Image.file(
                    widget.frame.file,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Padding(
                      padding: const EdgeInsets.all(Tokens.spaceSection),
                      child: Text('This photo could not be opened.',
                          style: p.body),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: Tokens.spaceSection),
          ActionButton(
            label: 'Share this photo',
            icon: Icons.ios_share,
            onPressed: _share,
          ),
          const SizedBox(height: Tokens.spaceSnug),
          AccentPanel(
            accent: Tokens.statusWarn,
            background: p.canvas,
            child: Text(
              'Send it as a file or document. If you send it as a photo, apps '
              'like WhatsApp shrink it and the proof inside is lost.',
              style: p.body,
            ),
          ),
          const SizedBox(height: Tokens.spaceSection),
          const SectionHead(title: 'Saved details'),
          const SizedBox(height: Tokens.spaceSnug),
          FutureBuilder<SignedEnvelope?>(
            future: _future,
            builder:
                (BuildContext context, AsyncSnapshot<SignedEnvelope?> snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const LoadingState(message: 'Reading the details');
              }
              if (snap.hasError) {
                return const ErrorState(
                  message: 'The details could not be read from this file.',
                );
              }

              final SignedEnvelope? e = snap.data;
              if (e == null) {
                return const ErrorState(
                  message: 'No GeoGuard details found in this photo. They may '
                      'have been removed.',
                );
              }

              final DateTime captured = DateTime.fromMillisecondsSinceEpoch(
                e.timestampMs,
                isUtc: true,
              );

              return FieldCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(stamp, style: p.cardTitle),
                        ),
                        const StatusBadge(
                          label: 'signed',
                          color: Tokens.statusOk,
                        ),
                      ],
                    ),
                    const SizedBox(height: Tokens.spaceBase),
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
                    DataLine(label: 'Stamp code', value: e.pixelHash),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
