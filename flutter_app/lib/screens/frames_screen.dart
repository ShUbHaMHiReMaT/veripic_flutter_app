import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../services/frame_store.dart';
import '../theme/veripic_theme.dart';
import 'frame_detail_screen.dart';

/// Scrollable grid of frames this app captured, newest first.
///
/// Only frames GeoGuard stamped and signed appear here — this is never the
/// device's camera roll.
class FramesScreen extends StatefulWidget {
  const FramesScreen({super.key, this.standalone = false});

  /// True when this screen was pushed as its own route rather than shown as a
  /// tab inside the shell.
  ///
  /// The tab version draws into the shell's Scaffold. Pushed as a route with
  /// no Scaffold of its own it had no app bar, no background and no way back —
  /// which is what the camera's thumbnail button opened.
  final bool standalone;

  @override
  State<FramesScreen> createState() => _FramesScreenState();
}

class _FramesScreenState extends State<FramesScreen> {
  final FrameStore _store = FrameStore();

  late Future<List<StoredFrame>> _future = _store.list();

  @override
  void initState() {
    super.initState();
    // This screen lives inside the shell's IndexedStack, so it is built once
    // and never rebuilt when the tab is re-selected. Without this listener a
    // new capture only showed up after the app was killed and reopened.
    FrameStore.revision.addListener(_refresh);
  }

  @override
  void dispose() {
    FrameStore.revision.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _future = _store.list());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = _buildBody(context);
    if (!widget.standalone) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('Photos')),
      body: body,
    );
  }

  Widget _buildBody(BuildContext context) {
    final Palette p = Palette.of(context);

    return FutureBuilder<List<StoredFrame>>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<List<StoredFrame>> snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(Tokens.spaceBase),
            child: LoadingState(message: 'Loading your photos'),
          );
        }

        if (snap.hasError) {
          return ErrorState(
            message: 'Your photos could not be loaded. Pull down to try '
                'again.',
            actionLabel: 'Try again',
            onAction: _refresh,
          );
        }

        final List<StoredFrame> frames = snap.data ?? const <StoredFrame>[];
        if (frames.isEmpty) {
          return const EmptyState(
            icon: Icons.photo_outlined,
            title: 'No photos yet',
            message: 'Photos you take are stamped, signed and kept here. Open '
                'the camera to take your first one.',
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
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
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

    // Press and hold deletes, so clearing several photos does not mean opening
    // each one.
    return GestureDetector(
      onLongPress: () => deleteFrameWithConfirm(context, frame),
      child: PressCard(
        padding: const EdgeInsets.all(Tokens.spaceTight),
        semanticLabel: 'Photo taken $stamp. Press and hold to delete.',
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
      ),
    );
  }
}
