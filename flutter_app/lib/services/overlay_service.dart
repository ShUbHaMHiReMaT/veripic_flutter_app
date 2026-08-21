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
    // Format per the design system: `21AUG26 09:14`. The UTC offset is read
    // from the device rather than hardcoded to a single region.
    final DateTime local = timestamp.toLocal();
    final Duration offset = local.timeZoneOffset;
    final String sign = offset.isNegative ? '-' : '+';
    final Duration abs = offset.abs();
    final String offsetStr = '$sign${abs.inHours.toString().padLeft(2, '0')}:'
        '${(abs.inMinutes % 60).toString().padLeft(2, '0')}';
    final String timeStr =
        '${DateFormat('ddMMMyy HH:mm').format(local).toUpperCase()} '
        'UTC$offsetStr';

    final int width = originalImage.width;
    final int height = originalImage.height;
    final int bannerHeight = (height * 0.18).toInt();
    final int bannerY = height - bannerHeight;

    // 1. Global Micro-Watermark Noise Across Whole Image
    _applyGlobalAntiAiGrid(originalImage);

    // 2. Stamp panel — sand at 92%. A panel, not a drop shadow: text with a
    //    shadow alone fails on bright sky and on dark shed interiors.
    img.fillRect(
      originalImage,
      x1: 0,
      y1: bannerY,
      x2: width,
      y2: height,
      color: img.ColorRgba8(240, 237, 228, 235),
    );

    // 3. Left accent bar, 3px of `signal`, scaled with the image so it stays
    //    visible on a full-resolution frame.
    final int barWidth = (width * 0.006).clamp(3, 24).toInt();
    img.fillRect(
      originalImage,
      x1: 0,
      y1: bannerY,
      x2: barWidth,
      y2: height,
      color: img.ColorRgba8(224, 122, 47, 255),
    );

    // 4. Dual-tone anti-AI pattern, kept at full amplitude but confined to a
    //    strip below the text so it never fights legibility.
    final int patternTop = height - (bannerHeight * 0.18).toInt();
    _drawAntiAiPattern(originalImage, patternTop, height, width);

    // Stamp type is a percentage of image height, never a fixed px — scaling a
    // screen-rendered overlay up produces soft, unusable text.
    final double targetPx = height * 0.022;
    final img.BitmapFont font = targetPx >= 36 ? img.arial48 : img.arial24;
    final int lineStep = (font.lineHeight * 1.25).toInt();

    final int left = barWidth + (width * 0.02).toInt();
    int currentY = bannerY + (bannerHeight * 0.10).toInt();

    // Line 1 — site name.
    img.drawString(
      originalImage,
      addressText.toUpperCase(),
      font: font,
      x: left,
      y: currentY,
      color: img.ColorRgba8(30, 42, 34, 255), // ink
    );
    currentY += lineStep;

    // Line 2 — coordinates.
    img.drawString(
      originalImage,
      '$latStr   $longStr',
      font: font,
      x: left,
      y: currentY,
      color: img.ColorRgba8(90, 107, 95, 255), // ink-soft
    );
    currentY += lineStep;

    // Line 3 — date and time.
    img.drawString(
      originalImage,
      timeStr,
      font: font,
      x: left,
      y: currentY,
      color: img.ColorRgba8(90, 107, 95, 255), // ink-soft
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