import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class NvidiaAnalysis {
  NvidiaAnalysis({
    required this.reachable,
    required this.rawResponse,
    this.syntheticScore,
    this.summary,
    this.error,
  });

  final bool reachable;
  final double? syntheticScore; // 0..1 where higher = more likely synthetic
  final String? summary;
  final String? error;
  final String rawResponse;
}

/// Sends the image to an NVIDIA Build hosted vision/multimodal model and
/// extracts a "does this look AI-generated / edited?" signal.
///
/// The exact request/response shape depends on the model chosen at
/// https://build.nvidia.com/models — this client uses the OpenAI-compatible
/// chat/completions surface that most NVIDIA-hosted vision models expose.
class NvidiaVisionService {
  NvidiaVisionService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String _endpoint = 'https://integrate.api.nvidia.com/v1/chat/completions';

  Future<NvidiaAnalysis> analyze(Uint8List imageBytes) async {
    final String? apiKey = _env('NVIDIA_API_KEY');
    final String model = _env('NVIDIA_MODEL_NAME') ?? 'nvidia/neva-22b';
    if (apiKey == null || apiKey.isEmpty || apiKey.startsWith('YOUR_')) {
      return NvidiaAnalysis(
        reachable: false,
        rawResponse: '',
        error: 'NVIDIA_API_KEY not configured in .env',
      );
    }

    final String b64 = base64Encode(imageBytes);
    final Map<String, dynamic> body = <String, dynamic>{
      'model': model,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'text':
                  'You are a forensic image analyst. Examine the image for signs of '
                      'AI generation, deepfake artifacts, inpainting, GAN fingerprints, '
                      'inconsistent lighting or noise. Respond ONLY as strict JSON: '
                      '{"synthetic_score": <0..1>, "summary": "<short reason>"}.'
            },
            <String, dynamic>{
              'type': 'image_url',
              'image_url': <String, String>{'url': 'data:image/png;base64,$b64'},
            },
          ],
        },
      ],
      'temperature': 0.0,
      'max_tokens': 256,
    };

    try {
      final http.Response res = await _client
          .post(
            Uri.parse(_endpoint),
            headers: <String, String>{
              'Authorization': 'Bearer $apiKey',
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));

      if (res.statusCode >= 400) {
        return NvidiaAnalysis(
          reachable: true,
          rawResponse: res.body,
          error: 'NVIDIA API returned ${res.statusCode}',
        );
      }

      final Map<String, dynamic> decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final String content = _extractContent(decoded);
      final Map<String, dynamic>? parsed = _extractJson(content);
      return NvidiaAnalysis(
        reachable: true,
        rawResponse: res.body,
        syntheticScore: parsed?['synthetic_score'] is num
            ? (parsed!['synthetic_score'] as num).toDouble()
            : null,
        summary: parsed?['summary'] as String? ?? content,
      );
    } catch (e) {
      return NvidiaAnalysis(
        reachable: false,
        rawResponse: '',
        error: e.toString(),
      );
    }
  }

  String _extractContent(Map<String, dynamic> resp) {
    try {
      final List<dynamic> choices = resp['choices'] as List<dynamic>;
      final Map<String, dynamic> msg = choices.first['message'] as Map<String, dynamic>;
      final dynamic content = msg['content'];
      if (content is String) return content;
      if (content is List) {
        return content
            .whereType<Map<String, dynamic>>()
            .map((Map<String, dynamic> c) => c['text']?.toString() ?? '')
            .join(' ');
      }
    } catch (_) {}
    return resp.toString();
  }

  Map<String, dynamic>? _extractJson(String text) {
    final int start = text.indexOf('{');
    final int end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      return jsonDecode(text.substring(start, end + 1)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  String? _env(String key) {
    try {
      return dotenv.maybeGet(key);
    } catch (_) {
      return null;
    }
  }
}
