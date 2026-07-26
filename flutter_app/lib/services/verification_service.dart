import 'dart:typed_data';

import 'security_service.dart';
import 'nvidia_vision_service.dart';

enum VerificationVerdict { authentic, tamperedPixels, tamperedMetadata, notSigned, error }

class VerificationReport {
  VerificationReport({
    required this.verdict,
    required this.reason,
    this.envelope,
    this.aiAnalysis,
  });

  final VerificationVerdict verdict;
  final String reason;
  final SignedEnvelope? envelope;
  final NvidiaAnalysis? aiAnalysis;

  bool get isAuthentic => verdict == VerificationVerdict.authentic;
}

/// Runs the full verification pipeline:
///   1. Extract embedded envelope from image LSBs.
///   2. Verify HMAC signature over the envelope.
///   3. Recompute the pixel hash and compare.
///   4. Ask NVIDIA vision model for a deepfake / synthetic score.
class VerificationService {
  VerificationService({
    SecurityService? security,
    NvidiaVisionService? nvidia,
  })  : _security = security ?? SecurityService(),
        _nvidia = nvidia ?? NvidiaVisionService();

  final SecurityService _security;
  final NvidiaVisionService _nvidia;

  Future<VerificationReport> verify(Uint8List pngBytes) async {
    try {
      final SignedEnvelope? envelope = _security.extractEnvelope(pngBytes);
      if (envelope == null) {
        // Even unsigned images still go through the AI check for context.
        final NvidiaAnalysis ai = await _nvidia.analyze(pngBytes);
        return VerificationReport(
          verdict: VerificationVerdict.notSigned,
          reason: 'No VeriPic signature found in this image.',
          aiAnalysis: ai,
        );
      }

      final bool sigOk = await _security.verifySignature(envelope);
      if (!sigOk) {
        return VerificationReport(
          verdict: VerificationVerdict.tamperedMetadata,
          reason: 'HMAC signature mismatch — envelope fields were altered.',
          envelope: envelope,
          aiAnalysis: await _nvidia.analyze(pngBytes),
        );
      }

      final String recomputed = _security.recomputePixelHash(pngBytes);
      if (recomputed != envelope.pixelHash) {
        return VerificationReport(
          verdict: VerificationVerdict.tamperedPixels,
          reason: 'Pixel hash mismatch — image content was modified.',
          envelope: envelope,
          aiAnalysis: await _nvidia.analyze(pngBytes),
        );
      }

      final NvidiaAnalysis ai = await _nvidia.analyze(pngBytes);
      return VerificationReport(
        verdict: VerificationVerdict.authentic,
        reason: 'Signature, pixel hash and metadata all match.',
        envelope: envelope,
        aiAnalysis: ai,
      );
    } catch (e) {
      return VerificationReport(
        verdict: VerificationVerdict.error,
        reason: 'Verification failed: $e',
      );
    }
  }
}
