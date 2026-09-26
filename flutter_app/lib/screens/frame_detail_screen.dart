import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../config.dart';
import '../services/account_service.dart';
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
  final AccountService _account = AccountService();

  bool _sending = false;

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

  /// Sends the photo to another GeoGuard user, encrypted end to end.
  ///
  /// Unlike sharing as a file, nothing along the way can re-encode the image,
  /// so the signature inside survives intact.
  Future<void> _sendToUser() async {
    final DirectoryUser? who = await showModalBottomSheet<DirectoryUser>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PickRecipientSheet(account: _account),
    );
    if (who == null || !mounted) return;

    setState(() => _sending = true);
    try {
      final Uint8List bytes = await widget.frame.file.readAsBytes();
      await _account.sendPhoto(recipient: who, fileBytes: bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Sent to @${who.username}.')));
    } on AccountException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete() async {
    if (!await deleteFrameWithConfirm(context, widget.frame)) return;
    if (mounted) Navigator.of(context).pop();
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
          if (AppConfig.accountsEnabled &&
              AccountService.current.value != null) ...<Widget>[
            ActionButton(
              label: _sending ? 'Sending' : 'Send to a GeoGuard user',
              icon: Icons.send_outlined,
              color: Tokens.tintInfo,
              onPressed: _sending ? null : _sendToUser,
            ),
            const SizedBox(height: Tokens.spaceSnug),
          ],
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
          const SizedBox(height: Tokens.spaceSnug),
          ActionButton(
            label: 'Delete photo',
            icon: Icons.delete_outline,
            color: Tokens.statusAlert,
            onPressed: _sending ? null : _delete,
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

/// Picks who to send a photo to, from the username directory.
class _PickRecipientSheet extends StatefulWidget {
  const _PickRecipientSheet({required this.account});

  final AccountService account;

  @override
  State<_PickRecipientSheet> createState() => _PickRecipientSheetState();
}

class _PickRecipientSheetState extends State<_PickRecipientSheet> {
  final TextEditingController _controller = TextEditingController();

  Timer? _debounce;
  List<DirectoryUser> _results = const <DirectoryUser>[];
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(value));
  }

  Future<void> _run(String query) async {
    if (query.trim().length < 2) {
      setState(() => _results = const <DirectoryUser>[]);
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final List<DirectoryUser> found = await widget.account.search(query);
      if (mounted) setState(() => _results = found);
    } on AccountException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: p.surface,
          border: Border(top: p.side, left: p.side, right: p.side),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Tokens.radiusCard),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(Tokens.spaceBase),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SectionHead(title: 'Send to'),
                const SizedBox(height: Tokens.spaceSnug),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  style: p.body,
                  cursorColor: p.textPrimary,
                  onChanged: _onChanged,
                  decoration: InputDecoration(
                    hintText: 'username',
                    prefixText: '@',
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
                const SizedBox(height: Tokens.spaceBase),
                if (_error != null)
                  ErrorState(message: _error!)
                else if (_searching)
                  const LoadingState(message: 'Searching')
                else if (_results.isEmpty)
                  Text('Type at least two letters.', style: p.body)
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _results.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: Tokens.spaceTight),
                      itemBuilder: (BuildContext context, int i) {
                        final DirectoryUser u = _results[i];
                        return PressCard(
                          // Somebody who has published no encryption key
                          // cannot be sent to, so the row is inert and says
                          // why rather than failing after the tap.
                          onTap: u.canReceive
                              ? () => Navigator.of(context).pop(u)
                              : null,
                          padding: const EdgeInsets.all(Tokens.spaceSnug),
                          color: u.canReceive ? p.surface : p.surfaceInset,
                          child: Row(
                            children: <Widget>[
                              IconTile(
                                icon: u.canReceive
                                    ? Icons.person_outline
                                    : Icons.person_off_outlined,
                                color: u.canReceive
                                    ? Tokens.statusOk
                                    : Tokens.tintNull,
                                size: Tokens.tileSize - Tokens.spaceSnug,
                              ),
                              const SizedBox(width: Tokens.spaceSnug),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Text('@${u.username}', style: p.cardTitle),
                                    const SizedBox(height: Tokens.spaceHair),
                                    Text(
                                      u.canReceive
                                          ? u.fingerprint.toUpperCase()
                                          : 'Cannot receive photos yet',
                                      style: p.dataSmall,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks before deleting [frame], then deletes it.
///
/// Returns true when the photo is gone. Shared by the photo page and the
/// press-and-hold on the Photos grid, so both say the same thing.
Future<bool> deleteFrameWithConfirm(
  BuildContext context,
  StoredFrame frame,
) async {
  HapticFeedback.mediumImpact();
  final bool? go = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) {
      final Palette p = Palette.of(context);
      return Dialog(
        backgroundColor: p.surface,
        shape:
            RoundedRectangleBorder(borderRadius: Tokens.brCard, side: p.side),
        child: Padding(
          padding: const EdgeInsets.all(Tokens.spaceBase),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SectionHead(title: 'Delete this photo?'),
              const SizedBox(height: Tokens.spaceSnug),
              Text(
                'It is removed from GeoGuard and cannot be brought back. The '
                'copy in your phone gallery stays.',
                style: p.body,
              ),
              const SizedBox(height: Tokens.spaceBase),
              ActionButton(
                label: 'Delete photo',
                icon: Icons.delete_outline,
                color: Tokens.statusAlert,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: Tokens.spaceSnug),
              ActionButton(
                label: 'Keep it',
                color: p.surfaceInset,
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (go != true) return false;

  try {
    await FrameStore().delete(frame);
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('The photo could not be deleted. Try again.'),
        ));
    }
    return false;
  }
}
