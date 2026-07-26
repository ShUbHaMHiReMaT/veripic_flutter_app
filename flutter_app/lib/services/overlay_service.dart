import 'dart:typed_data';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';

class OverlayService {
  static Future<Uint8List> applyGpsStamp({
    required Uint8List imageBytes,
    required Position position,
  }) async {
    final img.Image? originalImage = img.decodeImage(imageBytes);
    if (originalImage == null) return imageBytes;

    String addressText =
        'Lat: ${position.latitude.toStringAsFixed(6)}, '
        'Long: ${position.longitude.toStringAsFixed(6)}';
    try {
      final List<Placemark> placemarks =
          await Geocoding().placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );
      if (placemarks.isNotEmpty) {
        final Placemark place = placemarks.first;
        addressText = <String?>[
          place.subLocality,
          place.locality,
          place.administrativeArea,
          place.country,
        ].whereType<String>().where((part) => part.isNotEmpty).join(', ');
      }
    } catch (_) {
      // Fall back to the coordinate string when reverse geocoding fails.
    }

    final String latStr = 'Lat ${position.latitude.toStringAsFixed(6)} deg';
    final String longStr =
        'Long ${position.longitude.toStringAsFixed(6)} deg';
    final DateTime now = DateTime.now();
    final Duration offset = now.timeZoneOffset;
    final String offsetSign = offset.isNegative ? '-' : '+';
    final String offsetText =
        '${offsetSign}${offset.inHours.abs().toString().padLeft(2, '0')}:'
        '${(offset.inMinutes.abs() % 60).toString().padLeft(2, '0')}';
    final String timeStr =
        '${DateFormat('dd/MM/yy hh:mm a').format(now)} GMT$offsetText';

    final int width = originalImage.width;
    final int height = originalImage.height;
    final int bannerHeight = (height * 0.18).toInt();
    final int bannerY = height - bannerHeight;

    img.fillRect(
      originalImage,
      x1: 0,
      y1: bannerY,
      x2: width,
      y2: height,
      color: img.ColorRgba8(0, 0, 0, 180),
    );

    final font = img.arial24;
    int currentY = bannerY + 20;

    img.drawString(
      originalImage,
      'VeriPic GPS Camera',
      font: font,
      x: 30,
      y: currentY,
      color: img.ColorRgba8(0, 230, 150, 255),
    );
    currentY += 35;

    img.drawString(
      originalImage,
      addressText,
      font: font,
      x: 30,
      y: currentY,
      color: img.ColorRgba8(255, 255, 255, 255),
    );
    currentY += 35;

    img.drawString(
      originalImage,
      '$latStr   $longStr',
      font: font,
      x: 30,
      y: currentY,
      color: img.ColorRgba8(220, 220, 220, 255),
    );
    currentY += 35;

    img.drawString(
      originalImage,
      timeStr,
      font: font,
      x: 30,
      y: currentY,
      color: img.ColorRgba8(200, 200, 200, 255),
    );

    return Uint8List.fromList(img.encodeJpg(originalImage, quality: 90));
  }
}
