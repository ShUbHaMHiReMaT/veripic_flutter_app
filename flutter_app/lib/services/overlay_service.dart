import 'package:geocoding/geocoding.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';

/// Burns the GPS stamp into a captured frame.
///
/// Every method here is pure pixel work: no network, no plugins, no encoding.
/// That is deliberate — this runs inside the capture isolate, where platform
/// channels are unreachable, and it used to block the shutter for seconds by
/// reverse-geocoding over the network mid-capture. The address is resolved
/// ahead of time by [resolveAddress] on the UI isolate and handed in.
class OverlayService {
  static const int _patternSpacing = 4;
  static final img.ColorRgba8 _patternColorA = img.ColorRgba8(230, 150, 60, 255);
  static final img.ColorRgba8 _patternColorB = img.ColorRgba8(40, 90, 150, 255);

  static const String fallbackAddress = 'Location not named';

  /// Draws the stamp directly onto [image]. Mutates in place and encodes
  /// nothing — the caller encodes once, at the end of the pipeline.
  static void drawStamp(
    img.Image image, {
    required double latitude,
    required double longitude,
    required DateTime timestampUtc,
    required String addressText,
  }) {
    final String latStr = 'Lat ${latitude.toStringAsFixed(6)} deg';
    final String longStr = 'Long ${longitude.toStringAsFixed(6)} deg';

    // Format per the design system: `21AUG26 09:14`. The UTC offset is read
    // from the device rather than hardcoded to a single region.
    final DateTime local = timestampUtc.toLocal();
    final Duration offset = local.timeZoneOffset;
    final String sign = offset.isNegative ? '-' : '+';
    final Duration abs = offset.abs();
    final String offsetStr = '$sign${abs.inHours.toString().padLeft(2, '0')}:'
        '${(abs.inMinutes % 60).toString().padLeft(2, '0')}';
    final String timeStr =
        '${DateFormat('ddMMMyy HH:mm').format(local).toUpperCase()} '
        'UTC$offsetStr';

    final int width = image.width;
    final int height = image.height;
    final int bannerHeight = (height * 0.18).toInt();
    final int bannerY = height - bannerHeight;

    // 1. Global micro-watermark noise across the whole image.
    _applyGlobalAntiAiGrid(image);

    // 2. Stamp panel — sand at 92%. A panel, not a drop shadow: text with a
    //    shadow alone fails on bright sky and on dark shed interiors.
    img.fillRect(
      image,
      x1: 0,
      y1: bannerY,
      x2: width,
      y2: height,
      color: img.ColorRgba8(240, 237, 228, 235),
    );

    // 3. Left accent bar, scaled with the image so it stays visible on a
    //    full-resolution frame.
    final int barWidth = (width * 0.006).clamp(3, 24).toInt();
    img.fillRect(
      image,
      x1: 0,
      y1: bannerY,
      x2: barWidth,
      y2: height,
      color: img.ColorRgba8(224, 122, 47, 255),
    );

    // 4. Dual-tone anti-AI pattern, kept at full amplitude but confined to a
    //    strip below the text so it never fights legibility.
    final int patternTop = height - (bannerHeight * 0.18).toInt();
    _drawAntiAiPattern(image, patternTop, height, width);

    // Stamp type is a percentage of image height, never a fixed px — scaling a
    // screen-rendered overlay up produces soft, unusable text.
    final double targetPx = height * 0.022;
    final img.BitmapFont font = targetPx >= 36 ? img.arial48 : img.arial24;
    final int lineStep = (font.lineHeight * 1.25).toInt();

    final int left = barWidth + (width * 0.02).toInt();
    int currentY = bannerY + (bannerHeight * 0.10).toInt();

    // Line 1 — site name.
    img.drawString(
      image,
      addressText.toUpperCase(),
      font: font,
      x: left,
      y: currentY,
      color: img.ColorRgba8(30, 42, 34, 255), // ink
    );
    currentY += lineStep;

    // Line 2 — coordinates.
    img.drawString(
      image,
      '$latStr   $longStr',
      font: font,
      x: left,
      y: currentY,
      color: img.ColorRgba8(90, 107, 95, 255), // ink-soft
    );
    currentY += lineStep;

    // Line 3 — date and time.
    img.drawString(
      image,
      timeStr,
      font: font,
      x: left,
      y: currentY,
      color: img.ColorRgba8(90, 107, 95, 255), // ink-soft
    );
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

  /// Reverse-geocodes a coordinate into the line printed on the stamp.
  ///
  /// Call this *before* the shutter, never during: it is a network round trip.
  static Future<String> resolveAddress(double latitude, double longitude) async {
    try {
      final List<Placemark> placemarks =
          await placemarkFromCoordinates(latitude, longitude);
      if (placemarks.isEmpty) return fallbackAddress;

      final Placemark p = placemarks.first;
      final List<String> parts = <String>[
        if (p.street != null && p.street!.isNotEmpty) p.street!,
        if (p.subLocality != null && p.subLocality!.isNotEmpty) p.subLocality!,
        if (p.locality != null && p.locality!.isNotEmpty) p.locality!,
        if (p.administrativeArea != null && p.administrativeArea!.isNotEmpty)
          p.administrativeArea!,
        if (p.country != null && p.country!.isNotEmpty) p.country!,
      ];

      return parts.isNotEmpty ? parts.join(', ') : fallbackAddress;
    } catch (_) {
      return fallbackAddress;
    }
  }
}
