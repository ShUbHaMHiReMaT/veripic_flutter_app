import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../services/frame_store.dart';
import '../theme/veripic_theme.dart';
import 'frame_detail_screen.dart';

/// Scrollable grid of frames this app captured, newest first.
///
/// Only frames VeriPic stamped and signed appear here — this is never the
/// device's camera roll.
class FramesScreen extends StatefulWidget {
  const FramesScreen({super.key});

  @override
  State<FramesScreen> createState() => _FramesScreenState();
}

class _FramesScreenState extends State<FramesScreen> {
  final FrameStore _store = FrameStore();

  late Future<List<StoredFrame>> _future = _store.list();

  Future<void> _refresh() async {
    setState(() => _future = _store.list());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Frames')),
      body: FutureBuilder<List<StoredFrame>>(
        future: _future,
        builder:
            (BuildContext context, AsyncSnapshot<List<StoredFrame>> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(Tokens.spaceBase),
              child: LoadingState(message: 'Reading stored frames'),
            );
          }

          if (snap.hasError) {
            return ErrorState(
              message: 'Stored frames could not be read. Pull down to try '
                  'again.',
              actionLabel: 'Try again',
              onAction: _refresh,
            );
          }

          final List<StoredFrame> frames = snap.data ?? const <StoredFrame>[];
          if (frames.isEmpty) {
            return const EmptyState(
              icon: Icons.photo_outlined,
              title: 'No frames yet',
              message: 'Frames you capture are stamped, signed, and collected '
                  'here. Open the viewfinder to take the first one.',
            );
          }

          return RefreshIndicator(
            onRefresh: _refresh,
            color: p.textPrimary,
            backgroundColor: p.surface,
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(
                Tokens.spaceBase,
                Tokens.spaceBase,
                Tokens.spaceBase,
                Tokens.spaceScreen,
              ),
              physics: const AlwaysScrollableScrollPhysics(),
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisSpacing: Tokens.spaceBase,
                crossAxisSpacing: Tokens.spaceSnug,
                childAspectRatio: 0.82,
              ),
              itemCount: frames.length,
              itemBuilder: (BuildContext context, int i) =>
                  _FrameCell(frame: frames[i]),
            ),
          );
        },
      ),
    );
  }
}

class _FrameCell extends StatelessWidget {
  const _FrameCell({required this.frame});

  final StoredFrame frame;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final String stamp =
        DateFormat('ddMMMyy HH:mm').format(frame.capturedAt).toUpperCase();

    return PressCard(
      padding: const EdgeInsets.all(Tokens.spaceTight),
      semanticLabel: 'Frame captured $stamp',
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FrameDetailScreen(frame: frame),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: Tokens.brControl,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.surfaceInset,
                  border: Border.all(
                    color: p.outline,
                    width: Tokens.borderWidth,
                  ),
                  borderRadius: Tokens.brControl,
                ),
                child: Image.file(
                  frame.file,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.broken_image_outlined,
                    color: p.textSecondary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: Tokens.spaceTight),
          Text(stamp, style: p.dataSmall),
        ],
      ),
    );
  }
}
