import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'nvidia_vision_service.dart';
import 'security_service.dart';

enum VerificationVerdict {
  authentic,
  tamperedPixels,
  tamperedMetadata,
  notSigned,
  error
}

class VerificationReport {
  VerificationReport({
    required this.verdict,
    required this.reason,
    this.envelope,
    this.aiAnalysis,
    this.hammingDistance = 0,
  });

  final VerificationVerdict verdict;
  final String reason;
  final SignedEnvelope? envelope;
  final NvidiaAnalysis? aiAnalysis;
  final int hammingDistance;

  bool get isAuthentic => verdict == VerificationVerdict.authentic;
}

class VerificationService {
  VerificationService({
    SecurityService? security,
    NvidiaVisionService? nvidia,
  })  : _security = security ?? SecurityService(),
        _nvidia = nvidia ?? NvidiaVisionService();

  final SecurityService _security;
  final NvidiaVisionService _nvidia;

  Future<VerificationReport> verify(Uint8List imageBytes) async {
    try {
      final SignedEnvelope? envelope = _security.extractEnvelope(imageBytes);

      Future<NvidiaAnalysis?> safeAnalyze(Uint8List bytes) async {
        try {
          return await _nvidia.analyze(bytes);
        } catch (_) {
          return null;
        }
      }

      if (envelope == null) {
        return VerificationReport(
          verdict: VerificationVerdict.notSigned,
          reason:
              'No VeriPic signature found in EXIF/Metadata. Image was edited or stripped.',
          aiAnalysis: await safeAnalyze(imageBytes),
        );
      }

      final bool sigOk = await _security.verifySignature(envelope);
      if (!sigOk) {
        return VerificationReport(
          verdict: VerificationVerdict.tamperedMetadata,
          reason: 'HMAC Signature Mismatch: Metadata payload was altered.',
          envelope: envelope,
          aiAnalysis: await safeAnalyze(imageBytes),
        );
      }

      final img.Image? decoded = img.decodeImage(imageBytes);
      if (decoded == null) {
        return VerificationReport(
          verdict: VerificationVerdict.error,
          reason: 'Failed to decode image bytes.',
        );
      }

      final String currentDHash = _security.computeBannerDHash(decoded);
      final int distance =
          _security.hammingDistance(currentDHash, envelope.pixelHash);

      if (distance > SecurityService.maxPerceptualHammingDistance) {
        return VerificationReport(
          verdict: VerificationVerdict.tamperedPixels,
          reason:
              'TAMPER DETECTED (Hamming Distance: $distance): Banner text or date was edited.',
          envelope: envelope,
          aiAnalysis: await safeAnalyze(imageBytes),
          hammingDistance: distance,
        );
      }

      return VerificationReport(
        verdict: VerificationVerdict.authentic,
        reason: 'Image Authentic: Perceptual fingerprint matches original capture.',
        envelope: envelope,
        aiAnalysis: await safeAnalyze(imageBytes),
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