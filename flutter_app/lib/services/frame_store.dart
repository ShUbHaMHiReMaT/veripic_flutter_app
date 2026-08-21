import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// One frame this app captured, as it exists on disk.
class StoredFrame {
  const StoredFrame({required this.file, required this.capturedAt});

  final File file;
  final DateTime capturedAt;

  String get path => file.path;
}

/// Read-only index of the frames this app has written.
///
/// Deliberately scoped to GeoGuard's own output — it enumerates the files the
/// capture pipeline already writes and never reads the device camera roll, so
/// only frames this app stamped and signed can appear in the gallery.
///
/// This does not change the capture pipeline; it only reads what that pipeline
/// has already produced.
class FrameStore {
  /// Filename shape written by the capture pipeline: `geoguard_<millis>.png`.
  /// The former `veripic_` prefix is still matched so frames captured before
  /// the rename remain visible in the gallery.
  static final RegExp _namePattern =
      RegExp(r'^(?:geoguard|veripic)_(\d+)\.png$');

  /// Every stored frame, newest first.
  Future<List<StoredFrame>> list() async {
    try {
      final Directory dir = await getTemporaryDirectory();
      if (!dir.existsSync()) return const <StoredFrame>[];

      final List<StoredFrame> frames = <StoredFrame>[];
      for (final FileSystemEntity entity in dir.listSync()) {
        if (entity is! File) continue;
        final String name = entity.uri.pathSegments.last;
        final RegExpMatch? m = _namePattern.firstMatch(name);
        if (m == null) continue;

        final int? millis = int.tryParse(m.group(1)!);
        if (millis == null) continue;

        frames.add(StoredFrame(
          file: entity,
          capturedAt: DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true)
              .toLocal(),
        ));
      }

      frames.sort((StoredFrame a, StoredFrame b) =>
          b.capturedAt.compareTo(a.capturedAt));
      return frames;
    } catch (_) {
      // Storage unavailable — an empty gallery is better than a crash.
      return const <StoredFrame>[];
    }
  }
}
