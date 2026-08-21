import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final String stamp = DateFormat('ddMMMyy HH:mm')
        .format(widget.frame.capturedAt)
        .toUpperCase();

    return Scaffold(
      appBar: AppBar(title: const Text('Frame')),
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
                      child: Text('This frame could not be opened.',
                          style: p.body),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: Tokens.spaceSection),
          const SectionHead(title: 'Sealed payload'),
          const SizedBox(height: Tokens.spaceSnug),
          FutureBuilder<SignedEnvelope?>(
            future: _future,
            builder:
                (BuildContext context, AsyncSnapshot<SignedEnvelope?> snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const LoadingState(message: 'Reading payload');
              }
              if (snap.hasError) {
                return const ErrorState(
                  message: 'The payload could not be read from this file.',
                );
              }

              final SignedEnvelope? e = snap.data;
              if (e == null) {
                return const ErrorState(
                  message: 'No VeriPic payload found in this frame. Its '
                      'metadata may have been stripped.',
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
                          label: 'sealed',
                          color: Tokens.statusOk,
                        ),
                      ],
                    ),
                    const SizedBox(height: Tokens.spaceBase),
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
                    DataLine(label: 'Banner hash', value: e.pixelHash),
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
