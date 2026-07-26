import 'dart:typed_data';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';

class OverlayService {
  static const int _patternSpacing = 4;
  static final img.ColorRgba8 _patternColorA = img.ColorRgba8(230, 150, 60, 255);
  static final img.ColorRgba8 _patternColorB = img.ColorRgba8(40, 90, 150, 255);

  static Future<Uint8List> applyGpsStamp({
    required Uint8List imageBytes,
    required Position position,
    required DateTime timestamp,
  }) async {
    final img.Image? originalImage = img.decodeImage(imageBytes);
    if (originalImage == null) return imageBytes;

    final String addressText = await _resolveAddress(position);

    final String latStr = 'Lat ${position.latitude.toStringAsFixed(6)} deg';
    final String longStr = 'Long ${position.longitude.toStringAsFixed(6)} deg';
    final String timeStr =
        '${DateFormat('dd/MM/yy hh:mm a').format(timestamp.toLocal())} GMT+05:30';

    final int width = originalImage.width;
    final int height = originalImage.height;
    final int bannerHeight = (height * 0.18).toInt();
    final int bannerY = height - bannerHeight;

    // 1. Global Micro-Watermark Noise Across Whole Image
    _applyGlobalAntiAiGrid(originalImage);

    // 2. Dark Translucent Overlay Banner
    img.fillRect(
      originalImage,
      x1: 0,
      y1: bannerY,
      x2: width,
      y2: height,
      color: img.ColorRgba8(0, 0, 0, 210),
    );

    // 3. Dense Dual-Tone Anti-AI Pattern on Banner Zone
    _drawAntiAiPattern(originalImage, bannerY, height, width);

    final font = img.arial24;
    int currentY = bannerY + 12;

    img.drawString(
      originalImage,
      'VeriPic GPS Camera  [SECURE-STAMP]',
      font: font,
      x: 25,
      y: currentY,
      color: img.ColorRgba8(0, 230, 150, 255),
    );
    currentY += 30;

    img.drawString(
      originalImage,
      addressText,
      font: font,
      x: 25,
      y: currentY,
      color: img.ColorRgba8(255, 255, 255, 255),
    );
    currentY += 30;

    img.drawString(
      originalImage,
      '$latStr   $longStr',
      font: font,
      x: 25,
      y: currentY,
      color: img.ColorRgba8(220, 220, 220, 255),
    );
    currentY += 30;

    img.drawString(
      originalImage,
      timeStr,
      font: font,
      x: 25,
      y: currentY,
      color: img.ColorRgba8(200, 200, 200, 255),
    );

    return Uint8List.fromList(img.encodeJpg(originalImage, quality: 95));
  }

  static void _applyGlobalAntiAiGrid(img.Image image) {
    for (int y = 0; y < image.height; y += 12) {
      for (int x = 0; x < image.width; x += 12) {
        final img.Pixel p = image.getPixel(x, y);
        final int val = ((x + y) % 24 == 0) ? 3 : -3;
        image.setPixelRgba(
          x,
          y,
          (p.r + val).clamp(0, 255).toInt(),
          (p.g + val).clamp(0, 255).toInt(),
          (p.b + val).clamp(0, 255).toInt(),
          p.a.toInt(),
        );
      }
    }
  }

  static void _drawAntiAiPattern(
    img.Image image,
    int bannerY,
    int height,
    int width,
  ) {
    for (int y = bannerY; y < height; y += _patternSpacing) {
      for (int x = 0; x < width; x += _patternSpacing) {
        final int cell = (x ~/ _patternSpacing) + (y ~/ _patternSpacing);
        if (cell % 2 == 0) {
          image.setPixelRgba(
            x,
            y,
            _patternColorA.r.toInt(),
            _patternColorA.g.toInt(),
              _patternColorA.b.toInt(),
              _patternColorA.a.toInt(),
          );
        } else if (cell % 3 == 0) {
          image.setPixelRgba(
            x,
            y,
            _patternColorB.r.toInt(),
            _patternColorB.g.toInt(),
            _patternColorB.b.toInt(),
            _patternColorB.a.toInt(),
          );
        }
      }
    }
  }

  static Future<String> _resolveAddress(Position position) async {
    const String fallback = 'Belagavi, Karnataka, India';
    try {
      final List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isEmpty) return fallback;

      final Placemark p = placemarks.first;
      final List<String> parts = [
        if (p.street != null && p.street!.isNotEmpty) p.street!,
        if (p.subLocality != null && p.subLocality!.isNotEmpty) p.subLocality!,
        if (p.locality != null && p.locality!.isNotEmpty) p.locality!,
        if (p.administrativeArea != null && p.administrativeArea!.isNotEmpty)
          p.administrativeArea!,
        if (p.country != null && p.country!.isNotEmpty) p.country!,
      ];

      return parts.isNotEmpty ? parts.join(', ') : fallback;
    } catch (_) {
      return fallback;
    }
  }
}