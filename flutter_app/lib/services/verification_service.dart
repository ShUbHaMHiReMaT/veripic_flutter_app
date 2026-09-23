import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'security_service.dart';

enum VerificationVerdict {
  authentic,
  tamperedScene,
  tamperedPixels,
  tamperedMetadata,
  notSigned,
  error,
}

/// The four forensic stages surfaced as an animated checklist in the UI.
enum VerifyStage {
  extract,
  hmac,
  dhash,
  scene,
}

extension VerifyStageInfo on VerifyStage {
  String get title => switch (this) {
        VerifyStage.extract => 'Looking for the hidden details',
        VerifyStage.hmac => 'Checking the signature',
        VerifyStage.dhash => 'Checking the stamp',
        VerifyStage.scene => 'Checking the picture',
      };

  String get code => switch (this) {
        VerifyStage.extract => 'DETAILS',
        VerifyStage.hmac => 'HMAC',
        VerifyStage.dhash => 'STAMP',
        VerifyStage.scene => 'PICTURE',
      };
}

enum StageState { pending, running, passed, failed, warned, skipped }

/// Emitted as each forensic stage begins and resolves.
typedef VerifyProgress = void Function(
  VerifyStage stage,
  StageState state,
  String? detail,
);

class VerificationReport {
  VerificationReport({
    required this.verdict,
    required this.reason,
    this.envelope,
    this.hammingDistance = 0,
    this.signatureCheck,
    this.recomputedHash,
    this.sceneTileDistances = const <int>[],
    this.alteredTiles = 0,
  });

  final VerificationVerdict verdict;
  final String reason;
  final SignedEnvelope? envelope;
  final int hammingDistance;

  /// Which key validated (or failed to validate) the envelope.
  final SignatureCheck? signatureCheck;

  /// The dHash recomputed from the supplied image, for side-by-side display.
  final String? recomputedHash;

  /// Per-tile Hamming distances across the photographic scene. Empty when the
  /// envelope predates scene protection.
  final List<int> sceneTileDistances;

  /// How many scene tiles exceeded the per-tile tolerance.
  final int alteredTiles;

  /// True when this envelope carried scene tile hashes at all.
  bool get sceneWasChecked => sceneTileDistances.isNotEmpty;

  bool get isAuthentic => verdict == VerificationVerdict.authentic;

}

class VerificationService {
  VerificationService({SecurityService? security})
      : _security = security ?? SecurityService();

  final SecurityService _security;

  Future<VerificationReport> verify(
    Uint8List imageBytes, {
    VerifyProgress? onProgress,
  }) async {
    void report(VerifyStage s, StageState st, [String? detail]) =>
        onProgress?.call(s, st, detail);


    try {
      // ---- Stage 1: payload extraction -------------------------------
      report(VerifyStage.extract, StageState.running);
      final SignedEnvelope? envelope = _security.extractEnvelope(imageBytes);

      if (envelope == null) {
        report(VerifyStage.extract, StageState.failed,
            'No GeoGuard details found');
        report(VerifyStage.hmac, StageState.skipped, 'Nothing to check');
        report(VerifyStage.dhash, StageState.skipped, 'No stamp to compare');
        report(VerifyStage.scene, StageState.skipped, 'No picture to compare');
        return VerificationReport(
          verdict: VerificationVerdict.notSigned,
          reason:
              'This photo has no GeoGuard details inside it. It was either not '
              'taken with GeoGuard, or the details were removed later.',
        );
      }

      report(
        VerifyStage.extract,
        StageState.passed,
        'Details found (v${envelope.version})'
        '${envelope.kid != null ? ' · key ${envelope.kid}' : ''}',
      );

      // ---- Stage 2: HMAC ---------------------------------------------
      report(VerifyStage.hmac, StageState.running);
      final SignatureCheck check =
          await _security.verifySignatureDetailed(envelope);

      if (!check.valid) {
        report(VerifyStage.hmac, StageState.failed,
            check.note ?? 'The signature does not match');
        report(VerifyStage.dhash, StageState.skipped,
            'Skipped — the signature failed');
        report(VerifyStage.scene, StageState.skipped,
            'Skipped — the signature failed');
        return VerificationReport(
          verdict: VerificationVerdict.tamperedMetadata,
          reason: check.note ??
              'The signature does not match, so something in this photo has '
                  'been changed since it was taken.',
          envelope: envelope,
          signatureCheck: check,
        );
      }

      report(
        VerifyStage.hmac,
        StageState.passed,
        check.isPortable
            ? 'The signature matches — any phone can check this photo'
            : check.matchedKey?.origin.plainLabel ?? 'The signature matches',
      );

      // ---- Stage 3: perceptual banner hash ---------------------------
      report(VerifyStage.dhash, StageState.running);
      final img.Image? decoded = img.decodeImage(imageBytes);
      if (decoded == null) {
        report(VerifyStage.dhash, StageState.failed,
            'This file could not be read');
        report(VerifyStage.scene, StageState.skipped,
            'The photo could not be read');
        return VerificationReport(
          verdict: VerificationVerdict.error,
          reason: 'This photo could not be read.',
          envelope: envelope,
          signatureCheck: check,
        );
      }

      final String currentDHash = _security.computeBannerDHash(decoded);
      final int distance =
          _security.hammingDistance(currentDHash, envelope.pixelHash);

      if (distance > SecurityService.maxPerceptualHammingDistance) {
        report(VerifyStage.dhash, StageState.failed,
            'The stamp differs in $distance of 64 spots, the limit is '
            '${SecurityService.maxPerceptualHammingDistance}');
        report(VerifyStage.scene, StageState.skipped,
            'Skipped — the stamp check already failed');
        return VerificationReport(
          verdict: VerificationVerdict.tamperedPixels,
          reason:
              'The stamp — the GPS text, place and time written on the photo — '
              'has been edited since the photo was taken. It differs in '
              '$distance of 64 spots.',
          envelope: envelope,
          signatureCheck: check,
          recomputedHash: currentDHash,
          hammingDistance: distance,
        );
      }

      report(VerifyStage.dhash, StageState.passed,
          'The stamp matches — $distance of 64 spots differ, limit '
          '${SecurityService.maxPerceptualHammingDistance}');

      // ---- Stage 4: photographic scene -------------------------------
      report(VerifyStage.scene, StageState.running);

      List<int> tileDistances = const <int>[];
      int altered = 0;

      if (!envelope.protectsScene) {
        // v4 and earlier protected only the banner, so there is nothing to
        // compare against. Say so rather than implying the scene passed.
        report(VerifyStage.scene, StageState.skipped,
            'Older photo (v${envelope.version}) — the picture was not protected');
      } else {
        final List<String> currentTiles = _security.computeSceneTiles(decoded);
        tileDistances =
            _security.compareSceneTiles(envelope.sceneTiles, currentTiles);

        if (tileDistances.isEmpty) {
          report(VerifyStage.scene, StageState.skipped,
              'The picture could not be compared');
        } else {
          altered = tileDistances
              .where((int d) => d > SecurityService.maxSceneTileHammingDistance)
              .length;

          if (altered > 0) {
            report(VerifyStage.scene, StageState.failed,
                '$altered of ${tileDistances.length} parts of the picture were '
                'changed');
            return VerificationReport(
              verdict: VerificationVerdict.tamperedScene,
              reason:
                  '$altered of ${tileDistances.length} parts of the picture no '
                  'longer match the original. The picture itself has been '
                  'edited, not just the stamp.',
              envelope: envelope,
              signatureCheck: check,
              recomputedHash: currentDHash,
              hammingDistance: distance,
              sceneTileDistances: tileDistances,
              alteredTiles: altered,
            );
          }

          report(VerifyStage.scene, StageState.passed,
              'All ${tileDistances.length} parts of the picture match');
        }
      }

      return VerificationReport(
        verdict: VerificationVerdict.authentic,
        reason: envelope.protectsScene
            ? 'This photo is real. The signature matches the phone that took '
                'it, and both the stamp and the picture are unchanged.'
            : 'This photo is real. The signature matches the phone that took '
                'it and the stamp is unchanged. This photo is older, so the '
                'picture itself was not protected.',
        envelope: envelope,
        signatureCheck: check,
        recomputedHash: currentDHash,
        hammingDistance: distance,
        sceneTileDistances: tileDistances,
        alteredTiles: altered,
      );
    } catch (e) {
      return VerificationReport(
        verdict: VerificationVerdict.error,
        reason: 'The check could not be finished: $e',
      );
    }
  }
}
