import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../services/account_service.dart';
import '../services/frame_store.dart';
import '../theme/veripic_theme.dart';

/// Photos other GeoGuard users have sent, still sealed.
///
/// Opening one decrypts it on this phone and saves the original file, so the
/// signature inside can be checked exactly as if it had never left the sender.
/// That is the whole reason photos travel this way: a chat app would have
/// re-encoded the image and stripped the proof out of it.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  final AccountService _account = AccountService();

  late Future<List<InboxItem>> _future = _account.inbox();
  String? _busyId;
  String? _error;

  Future<void> _refresh() async {
    setState(() {
      _future = _account.inbox();
      _error = null;
    });
    await _future;
  }

  Future<void> _open(InboxItem item) async {
    HapticFeedback.mediumImpact();
    setState(() {
      _busyId = item.id;
      _error = null;
    });

    try {
      final Uint8List original = await _account.receivePhoto(item);

      // Store it beside this phone's own captures so it appears in Photos and
      // on the map, and can be checked with the same pipeline.
      final Directory dir = await FrameStore.framesDirectory();
      final int stamp = (item.sentAt ?? DateTime.now()).millisecondsSinceEpoch;
      await File('${dir.path}/geoguard_$stamp.jpg').writeAsBytes(original);

      // Only drop the server copy once the file is safely on disk.
      await _account.deleteShare(item);
      FrameStore.notifyChanged();

      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('Photo from @${item.fromUsername} saved to Photos.'),
        ));
      await _refresh();
    } on AccountException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Sent to you')),
      body: FutureBuilder<List<InboxItem>>(
        future: _future,
        builder: (BuildContext context, AsyncSnapshot<List<InboxItem>> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(Tokens.spaceBase),
              child: LoadingState(message: 'Checking for photos'),
            );
          }
          if (snap.hasError) {
            return ErrorState(
              message: 'Could not check for photos. Try again.',
              actionLabel: 'Try again',
              onAction: _refresh,
            );
          }

          final List<InboxItem> items = snap.data ?? const <InboxItem>[];
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.inbox_outlined,
              title: 'Nothing sent to you',
              message: 'When somebody sends you a photo from GeoGuard, it '
                  'lands here. It stays locked until you open it — the server '
                  'cannot read it.',
            );
          }

          return RefreshIndicator(
            onRefresh: _refresh,
            color: p.textPrimary,
            backgroundColor: p.surface,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                Tokens.spaceBase,
                Tokens.spaceBase,
                Tokens.spaceBase,
                Tokens.spaceScreen,
              ),
              children: <Widget>[
                if (_error != null) ...<Widget>[
                  ErrorState(message: _error!),
                  const SizedBox(height: Tokens.spaceSnug),
                ],
                for (final InboxItem item in items) ...<Widget>[
                  FieldCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            const IconTile(
                              icon: Icons.lock_outline,
                              color: Tokens.tintInfo,
                            ),
                            const SizedBox(width: Tokens.spaceSnug),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text('@${item.fromUsername}',
                                      style: p.cardTitle),
                                  const SizedBox(height: Tokens.spaceHair),
                                  Text(
                                    <String>[
                                      '${(item.bytes / 1024).round()} KB',
                                      if (item.sentAt != null)
                                        DateFormat('ddMMMyy HH:mm')
                                            .format(item.sentAt!.toLocal())
                                            .toUpperCase(),
                                    ].join('  ·  '),
                                    style: p.dataSmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Tokens.spaceSnug),
                        ActionButton(
                          label: _busyId == item.id
                              ? 'Opening'
                              : 'Open and save',
                          icon: Icons.lock_open_outlined,
                          onPressed:
                              _busyId == null ? () => _open(item) : null,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Tokens.spaceSnug),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
