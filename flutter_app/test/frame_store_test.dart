import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoguard/services/frame_store.dart';

/// Stands in for path_provider so the store can be exercised on the host.
///
/// Both directories the store reads are redirected into one scratch tree, the
/// same way they sit side by side on a device.
class _FakePathProvider {
  _FakePathProvider(this.root);

  final Directory root;

  Directory get documents => Directory('${root.path}/documents');
  Directory get temp => Directory('${root.path}/temp');

  void install() {
    documents.createSync(recursive: true);
    temp.createSync(recursive: true);

    const MethodChannel channel =
        MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
          return documents.path;
        case 'getTemporaryDirectory':
          return temp.path;
      }
      return null;
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _FakePathProvider paths;
  late FrameStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('geoguard_frames_test');
    paths = _FakePathProvider(root)..install();
    store = FrameStore();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a frame written by the capture pipeline is listed straight away',
      () async {
    // Exactly what CameraService does: resolve the directory, then write
    // `geoguard_<millis>.jpg` into it. The regression this guards is the two
    // halves drifting apart — a capture that lands somewhere the gallery never
    // reads looks, to the user, like the photo simply vanished.
    final Directory dir = await FrameStore.framesDirectory();
    final int millis = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;
    await File('${dir.path}/geoguard_$millis.jpg').writeAsBytes(<int>[1, 2, 3]);

    final List<StoredFrame> frames = await store.list();

    expect(frames, hasLength(1));
    expect(frames.single.capturedAt.toUtc(), DateTime.utc(2026, 3, 1, 12));
  });

  test('the durable directory sits inside application documents', () async {
    final Directory dir = await FrameStore.framesDirectory();

    // Not the temp directory: the OS reclaims that whenever it likes, which
    // silently deleted captures.
    expect(dir.path, startsWith(paths.documents.path));
    expect(dir.existsSync(), isTrue);
  });

  test('frames left in the old temp location are still listed', () async {
    final int older = DateTime.utc(2026, 2, 1).millisecondsSinceEpoch;
    final int newer = DateTime.utc(2026, 3, 1).millisecondsSinceEpoch;

    // A build before the move wrote here, with the old extension.
    await File('${paths.temp.path}/geoguard_$older.png')
        .writeAsBytes(<int>[1]);
    final Directory dir = await FrameStore.framesDirectory();
    await File('${dir.path}/geoguard_$newer.jpg').writeAsBytes(<int>[2]);

    final List<StoredFrame> frames = await store.list();

    expect(frames, hasLength(2));
    // Newest first.
    expect(frames.first.capturedAt.toUtc(), DateTime.utc(2026, 3, 1));
  });

  test('unrelated files in the same directories are ignored', () async {
    final Directory dir = await FrameStore.framesDirectory();
    await File('${dir.path}/notes.txt').writeAsBytes(<int>[1]);
    await File('${dir.path}/IMG_2043.jpg').writeAsBytes(<int>[1]);
    await File('${paths.temp.path}/geoguard_.jpg').writeAsBytes(<int>[1]);

    expect(await store.list(), isEmpty);
  });

  test('capturing bumps the revision the listing tabs listen to', () async {
    // The Photos and Locations tabs live in an IndexedStack, so they are built
    // once and never rebuilt on tab change. This notifier is the only thing
    // that tells them a new capture exists.
    int seen = 0;
    void listener() => seen++;
    FrameStore.revision.addListener(listener);
    addTearDown(() => FrameStore.revision.removeListener(listener));

    FrameStore.notifyChanged();
    FrameStore.notifyChanged();

    expect(seen, 2);
  });

  test('a deleted frame is gone, including a temp leftover of the same name',
      () async {
    // A leftover in the legacy temp directory would otherwise be listed again
    // and the photo would come straight back after deleting it.
    const String name = 'geoguard_1774269000000.jpg';
    final Directory durable = await FrameStore.framesDirectory();
    File('${durable.path}/$name').writeAsBytesSync(<int>[1, 2, 3]);
    File('${paths.temp.path}/$name').writeAsBytesSync(<int>[1, 2, 3]);

    final int before = FrameStore.revision.value;
    final List<StoredFrame> frames = await store.list();
    expect(frames, hasLength(1));

    await store.delete(frames.single);

    expect(await store.list(), isEmpty);
    expect(File('${paths.temp.path}/$name').existsSync(), isFalse);
    expect(FrameStore.revision.value, greaterThan(before));
  });
}
