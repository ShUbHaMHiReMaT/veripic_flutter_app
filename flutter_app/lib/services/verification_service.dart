import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'nvidia_vision_service.dart';
import 'security_service.dart';

enum VerificationVerdict {
  authentic,
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
  ai,
}

extension VerifyStageInfo on VerifyStage {
  String get title => switch (this) {
        VerifyStage.extract => 'Extracting EXIF / COM payload',
        VerifyStage.hmac => 'Validating hardware HMAC',
        VerifyStage.dhash => 'Scanning banner dHash gradients',
        VerifyStage.ai => 'Running NVIDIA multimodal check',
      };

  String get code => switch (this) {
        VerifyStage.extract => 'PAYLOAD',
        VerifyStage.hmac => 'HMAC',
        VerifyStage.dhash => 'DHASH',
        VerifyStage.ai => 'AI',
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
    this.aiAnalysis,
    this.hammingDistance = 0,
    this.signatureCheck,
    this.recomputedHash,
  });

  final VerificationVerdict verdict;
  final String reason;
  final SignedEnvelope? envelope;
  final NvidiaAnalysis? aiAnalysis;
  final int hammingDistance;

  /// Which key validated (or failed to validate) the envelope.
  final SignatureCheck? signatureCheck;

  /// The dHash recomputed from the supplied image, for side-by-side display.
  final String? recomputedHash;

  bool get isAuthentic => verdict == VerificationVerdict.authentic;

  /// 0..1 integrity confidence, blending HMAC validity, perceptual distance
  /// and (when available) the NVIDIA synthetic-content score.
  double get confidence {
    switch (verdict) {
      case VerificationVerdict.notSigned:
        return 0.0;
      case VerificationVerdict.error:
        return 0.0;
      case VerificationVerdict.tamperedMetadata:
        return 0.05;
      case VerificationVerdict.tamperedPixels:
        // Degrade smoothly with how far the banner drifted.
        return (1.0 - (hammingDistance / 64.0)).clamp(0.0, 0.4);
      case VerificationVerdict.authentic:
        final double perceptual = 1.0 -
            (hammingDistance / (SecurityService.maxPerceptualHammingDistance * 2))
                .clamp(0.0, 0.5);
        final double? synthetic = aiAnalysis?.syntheticScore;
        if (synthetic == null) return perceptual.clamp(0.0, 1.0);
        return (perceptual * (1.0 - synthetic * 0.5)).clamp(0.0, 1.0);
    }
  }
}

class VerificationService {
  VerificationService({
    SecurityService? security,
    NvidiaVisionService? nvidia,
  })  : _security = security ?? SecurityService(),
        _nvidia = nvidia ?? NvidiaVisionService();

  final SecurityService _security;
  final NvidiaVisionService _nvidia;

  Future<VerificationReport> verify(
    Uint8List imageBytes, {
    VerifyProgress? onProgress,
  }) async {
    void report(VerifyStage s, StageState st, [String? detail]) =>
        onProgress?.call(s, st, detail);

    Future<NvidiaAnalysis?> runAi(Uint8List bytes) async {
      report(VerifyStage.ai, StageState.running);
      try {
        final NvidiaAnalysis analysis = await _nvidia.analyze(bytes);
        if (analysis.error != null) {
          report(VerifyStage.ai, StageState.skipped, analysis.error);
        } else {
          final double? score = analysis.syntheticScore;
          report(
            VerifyStage.ai,
            score != null && score > 0.5 ? StageState.warned : StageState.passed,
            score == null
                ? 'Model returned no score'
                : 'Synthetic likelihood ${(score * 100).toStringAsFixed(1)}%',
          );
        }
        return analysis;
      } catch (e) {
        report(VerifyStage.ai, StageState.skipped, 'Endpoint unreachable');
        return null;
      }
    }

    try {
      // ---- Stage 1: payload extraction -------------------------------
      report(VerifyStage.extract, StageState.running);
      final SignedEnvelope? envelope = _security.extractEnvelope(imageBytes);

      if (envelope == null) {
        report(VerifyStage.extract, StageState.failed, 'No VeriPic payload found');
        report(VerifyStage.hmac, StageState.skipped, 'Nothing to validate');
        report(VerifyStage.dhash, StageState.skipped, 'No reference hash');
        return VerificationReport(
          verdict: VerificationVerdict.notSigned,
          reason:
              'No VeriPic signature found in EXIF/COM/EOF metadata. The image was '
              'never signed by VeriPic, or its metadata has been stripped.',
          aiAnalysis: await runAi(imageBytes),
        );
      }

      report(
        VerifyStage.extract,
        StageState.passed,
        'Envelope v${envelope.version} recovered'
        '${envelope.kid != null ? ' · key ${envelope.kid}' : ''}',
      );

      // ---- Stage 2: HMAC ---------------------------------------------
      report(VerifyStage.hmac, StageState.running);
      final SignatureCheck check =
          await _security.verifySignatureDetailed(envelope);

      if (!check.valid) {
        report(VerifyStage.hmac, StageState.failed,
            check.note ?? 'Signature mismatch');
        report(VerifyStage.dhash, StageState.skipped, 'Chain of trust broken');
        return VerificationReport(
          verdict: VerificationVerdict.tamperedMetadata,
          reason:
              'HMAC signature mismatch: the metadata payload was altered, or the '
              'photo was signed on a different device. ${check.note ?? ''}'.trim(),
          envelope: envelope,
          signatureCheck: check,
          aiAnalysis: await runAi(imageBytes),
        );
      }

      report(VerifyStage.hmac, StageState.passed,
          check.matchedKey?.origin.label ?? 'Signature valid');

      // ---- Stage 3: perceptual banner hash ---------------------------
      report(VerifyStage.dhash, StageState.running);
      final img.Image? decoded = img.decodeImage(imageBytes);
      if (decoded == null) {
        report(VerifyStage.dhash, StageState.failed, 'Undecodable image data');
        report(VerifyStage.ai, StageState.skipped, 'No decodable frame');
        return VerificationReport(
          verdict: VerificationVerdict.error,
          reason: 'Failed to decode image bytes.',
          envelope: envelope,
          signatureCheck: check,
        );
      }

      final String currentDHash = _security.computeBannerDHash(decoded);
      final int distance =
          _security.hammingDistance(currentDHash, envelope.pixelHash);

      if (distance > SecurityService.maxPerceptualHammingDistance) {
        report(VerifyStage.dhash, StageState.failed,
            'Hamming distance $distance exceeds threshold '
            '${SecurityService.maxPerceptualHammingDistance}');
        return VerificationReport(
          verdict: VerificationVerdict.tamperedPixels,
          reason:
              'Tamper detected (Hamming distance $distance): the stamp banner — '
              'GPS text, address or timestamp — has been edited since capture.',
          envelope: envelope,
          signatureCheck: check,
          recomputedHash: currentDHash,
          aiAnalysis: await runAi(imageBytes),
          hammingDistance: distance,
        );
      }

      report(VerifyStage.dhash, StageState.passed,
          'Hamming distance $distance / '
          '${SecurityService.maxPerceptualHammingDistance} tolerated');

      // ---- Stage 4: NVIDIA multimodal --------------------------------
      final NvidiaAnalysis? ai = await runAi(imageBytes);

      return VerificationReport(
        verdict: VerificationVerdict.authentic,
        reason:
            'Image authentic: hardware-bound signature valid and the perceptual '
            'fingerprint matches the original capture.',
        envelope: envelope,
        signatureCheck: check,
        recomputedHash: currentDHash,
        aiAnalysis: ai,
        hammingDistance: distance,
      );
    } catch (e) {
      return VerificationReport(
        verdict: VerificationVerdict.error,
        reason: 'Verification process encountered an error: $e',
      );
    }
  }
}
