import 'dart:io';

import 'package:flutter/foundation.dart';
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
class FrameStore {
  /// Filename shape written by the capture pipeline: `geoguard_<millis>.jpg`.
  /// The `.png` extension and the former `veripic_` prefix are still matched so
  /// frames captured by earlier builds remain visible.
  static final RegExp _namePattern =
      RegExp(r'^(?:geoguard|veripic)_(\d+)\.(?:png|jpg)$');

  /// Bumped whenever a capture lands on disk.
  ///
  /// The Frames and Locations tabs live inside an [IndexedStack], so their
  /// state is built once and never rebuilt when the tab is re-selected. Without
  /// a signal they kept showing the listing they read at startup, and a new
  /// capture only appeared after the app was killed and reopened. They listen
  /// to this instead.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void notifyChanged() => revision.value++;

  /// Durable home for captured frames.
  ///
  /// Application documents, *not* the temp directory: the OS reclaims temp
  /// space whenever it feels pressure, which silently deleted captures.
  static Future<Directory> framesDirectory() async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory dir = Directory('${base.path}/frames');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// Removes [frame] from this app and tells every listing to reload.
  ///
  /// Deletes the same filename from the legacy temp directory too, otherwise
  /// [list] would find that leftover and the photo would reappear. The copy
  /// saved to the phone's gallery at capture time is not touched: that one
  /// belongs to the user's gallery, not to GeoGuard.
  Future<void> delete(StoredFrame frame) async {
    final String name = frame.file.uri.pathSegments.last;
    final List<File> copies = <File>[frame.file];
    for (final Future<Directory> source in <Future<Directory>>[
      framesDirectory(),
      getTemporaryDirectory(),
    ]) {
      try {
        copies.add(File('${(await source).path}/$name'));
      } catch (_) {
        // A location that cannot be resolved has nothing of ours in it.
      }
    }

    for (final File f in copies) {
      if (await f.exists()) await f.delete();
    }
    notifyChanged();
  }

  /// Every stored frame, newest first.
  ///
  /// Reads the durable directory and the legacy temp directory, so frames
  /// written by earlier builds are not orphaned by the move.
  Future<List<StoredFrame>> list() async {
    final Map<String, StoredFrame> byName = <String, StoredFrame>{};

    for (final Future<Directory> source in <Future<Directory>>[
      framesDirectory(),
      getTemporaryDirectory(),
    ]) {
      try {
        final Directory dir = await source;
        if (!dir.existsSync()) continue;

        for (final FileSystemEntity entity in dir.listSync()) {
          if (entity is! File) continue;
          final String name = entity.uri.pathSegments.last;
          final RegExpMatch? m = _namePattern.firstMatch(name);
          if (m == null) continue;

          final int? millis = int.tryParse(m.group(1)!);
          if (millis == null) continue;

          // The durable copy is read first, so it wins over a temp leftover
          // of the same capture.
          byName.putIfAbsent(
            name,
            () => StoredFrame(
              file: entity,
              capturedAt:
                  DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true)
                      .toLocal(),
            ),
          );
        }
      } catch (_) {
        // One unreadable location must not empty the whole gallery.
      }
    }

    final List<StoredFrame> frames = byName.values.toList()
      ..sort((StoredFrame a, StoredFrame b) =>
          b.capturedAt.compareTo(a.capturedAt));
    return frames;
  }
}
