import 'dart:io';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'device_service.dart';
import 'security_service.dart';
import 'verification_service.dart';

/// Everything the operator must supply by hand, because the statute asks for
/// facts about a person and a device that the app cannot know on its own.
class CertificateParticulars {
  const CertificateParticulars({
    this.declarantName = '',
    this.declarantDesignation = '',
    this.declarantAddress = '',
    this.caseReference = '',
  });

  final String declarantName;
  final String declarantDesignation;
  final String declarantAddress;
  final String caseReference;
}

/// Builds an evidence certificate for a verified frame, laid out to follow the
/// structure of the certificate required by section 63(4) of the Bharatiya
/// Sakshya Adhiniyam, 2023 for electronic records.
///
/// IMPORTANT - read before relying on the output.
///
/// This produces a *draft* certificate pre-filled with the technical
/// particulars VeriPic can attest to from its own records. It is not, on its
/// own, a legally effective certificate:
///
///   * The statute requires the certificate to be signed. Part A must be signed
///     by the person in lawful control of the device that produced the record;
///     Part B by a person holding the relevant expert capacity. Both signature
///     blocks are left blank deliberately.
///   * Neither this app nor its author is providing legal advice, and no
///     representation is made that a court will admit the record.
///   * Whether these particulars satisfy a given court is a question for a
///     qualified lawyer in the relevant jurisdiction.
///
/// What the document does do is set out, accurately and in one place, exactly
/// what the app verified and by what method, so that a competent person can
/// review it and sign — or decline to.
class CertificateService {
  CertificateService({DeviceService? deviceService})
      : _deviceService = deviceService ?? DeviceService();

  final DeviceService _deviceService;

  static final DateFormat _stamp = DateFormat('dd MMMM yyyy, HH:mm:ss');

  /// Renders the certificate and returns the PDF bytes.
  Future<Uint8List> build({
    required VerificationReport report,
    required Uint8List imageBytes,
    CertificateParticulars particulars = const CertificateParticulars(),
  }) async {
    final DeviceFingerprint fingerprint = await _deviceService.resolve();
    final SignedEnvelope? envelope = report.envelope;
    final DateTime now = DateTime.now();

    final pw.Document doc = pw.Document(
      title: 'VeriPic evidence certificate',
      author: 'VeriPic',
    );

    final pw.MemoryImage? frame = _tryDecode(imageBytes);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(40, 40, 40, 48),
        footer: (pw.Context c) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 12),
          child: pw.Text(
            'VeriPic evidence certificate  ·  page ${c.pageNumber} of '
            '${c.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ),
        build: (pw.Context c) => <pw.Widget>[
          _title(),
          pw.SizedBox(height: 16),
          _preamble(particulars),
          pw.SizedBox(height: 16),
          _sectionHead('1. The electronic record'),
          _table(_recordRows(envelope, report, particulars)),
          pw.SizedBox(height: 14),
          _sectionHead('2. The device that produced it'),
          _table(_deviceRows(fingerprint, envelope)),
          pw.SizedBox(height: 14),
          _sectionHead('3. Manner of production'),
          _prose(_mannerOfProduction()),
          pw.SizedBox(height: 14),
          _sectionHead('4. Verification result'),
          _table(_verificationRows(report)),
          pw.SizedBox(height: 10),
          _verdictBanner(report),
          if (frame != null) ...<pw.Widget>[
            pw.SizedBox(height: 14),
            _sectionHead('5. The frame'),
            pw.SizedBox(height: 6),
            pw.Center(
              child: pw.Container(
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey600),
                ),
                child: pw.Image(frame, height: 260, fit: pw.BoxFit.contain),
              ),
            ),
          ],
          pw.SizedBox(height: 18),
          _sectionHead('6. Limits of this certificate'),
          _prose(_limitations(report)),
          pw.SizedBox(height: 20),
          _signatureBlock(
            'PART A — person in lawful control of the device',
            particulars,
          ),
          pw.SizedBox(height: 16),
          _signatureBlock(
            'PART B — person of expert capacity',
            const CertificateParticulars(),
          ),
          pw.SizedBox(height: 14),
          pw.Text(
            'Draft generated by VeriPic on ${_stamp.format(now)}. Unsigned, '
            'this document has no legal effect.',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ],
      ),
    );

    return doc.save();
  }

  /// Writes the certificate next to the app's other output and returns the file.
  Future<File> writeToFile({
    required VerificationReport report,
    required Uint8List imageBytes,
    CertificateParticulars particulars = const CertificateParticulars(),
  }) async {
    final Uint8List bytes = await build(
      report: report,
      imageBytes: imageBytes,
      particulars: particulars,
    );
    final Directory dir = await getTemporaryDirectory();
    final String name =
        'veripic_certificate_${DateTime.now().millisecondsSinceEpoch}.pdf';
    return File('${dir.path}/$name').writeAsBytes(bytes);
  }

  // -----------------------------------------------------------------------
  // Content
  // -----------------------------------------------------------------------

  pw.Widget _title() => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.Text(
            'CERTIFICATE IN RESPECT OF AN ELECTRONIC RECORD',
            style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 3),
          pw.Text(
            'Drafted to follow section 63(4), Bharatiya Sakshya Adhiniyam, 2023',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey800),
          ),
          pw.SizedBox(height: 8),
          pw.Divider(thickness: 1.2, color: PdfColors.black),
        ],
      );

  pw.Widget _preamble(CertificateParticulars p) => _prose(
        'I, ${_orBlank(p.declarantName)}, ${_orBlank(p.declarantDesignation)}, '
        'of ${_orBlank(p.declarantAddress)}, do hereby certify that the '
        'particulars set out below are true to the best of my knowledge and '
        'belief, and that the electronic record described in paragraph 1 was '
        'produced by the device described in paragraph 2 in the manner '
        'described in paragraph 3.',
      );

  List<List<String>> _recordRows(
    SignedEnvelope? e,
    VerificationReport report,
    CertificateParticulars p,
  ) {
    final List<List<String>> rows = <List<String>>[
      <String>['Case / file reference', _orBlank(p.caseReference)],
      <String>['Record type', 'Digital photograph (JPEG), stamped and signed'],
    ];

    if (e == null) {
      rows.add(<String>['Status', 'No VeriPic payload present in this file']);
      return rows;
    }

    final DateTime captured =
        DateTime.fromMillisecondsSinceEpoch(e.timestampMs, isUtc: true);

    rows.addAll(<List<String>>[
      <String>['Captured (UTC)', '${_stamp.format(captured)} UTC'],
      <String>[
        'Location recorded',
        '${e.lat.toStringAsFixed(6)}, ${e.lon.toStringAsFixed(6)}'
      ],
      <String>['Altitude recorded', '${e.alt.toStringAsFixed(1)} m'],
      <String>['Envelope schema', 'v${e.version}'],
      <String>['Banner fingerprint', e.pixelHash],
      <String>[
        'Scene fingerprints',
        e.protectsScene
            ? '${e.sceneTiles.length} tiles covering the photographic content'
            : 'Not present (frame predates scene protection)'
      ],
      <String>['Signature (HMAC-SHA256)', e.signature],
    ]);
    return rows;
  }

  List<List<String>> _deviceRows(
    DeviceFingerprint fp,
    SignedEnvelope? e,
  ) {
    final List<List<String>> rows = <List<String>>[
      <String>['Device', fp.label],
      <String>['Device hash (public)', fp.publicId],
      <String>[
        'Hardware identifier source',
        fp.attributes['Hardware ID source'] ?? 'unknown'
      ],
      <String>['Signing key id', e?.kid ?? 'not recorded'],
      <String>['Key derivation', 'HKDF-SHA256 (RFC 5869)'],
      <String>['Derivation salt', SecurityService.hkdfSalt],
      <String>['Derivation info', SecurityService.hkdfInfo],
    ];
    for (final String k in <String>['Platform', 'Manufacturer', 'Model']) {
      final String? v = fp.attributes[k];
      if (v != null && v.isNotEmpty) rows.add(<String>[k, v]);
    }
    if (fp.usedFallback) {
      rows.add(<String>[
        'Caveat',
        'No hardware identifier was available; the signing key is bound to a '
            'stored fallback value for this installation only.'
      ]);
    }
    return rows;
  }

  String _mannerOfProduction() =>
      'The photograph was captured by the VeriPic application running on the '
      'device described above. At the moment of capture the application '
      'obtained a satellite position fix, rejected the capture if the '
      'operating system reported that the position originated from a mock '
      'location provider, and burned the position, altitude and Coordinated '
      'Universal Time into the lower portion of the image as a visible stamp. '
      'It then computed a perceptual fingerprint of that stamp and of the '
      'photographic content, and computed a keyed hash (HMAC-SHA256) over the '
      'position, altitude, time, device identifier and those fingerprints. The '
      'key used is derived on the device from a hardware identifier by '
      'HKDF-SHA256 and is held in the platform keystore; it is not transmitted '
      'and does not leave the device. The resulting record was embedded into '
      'the image file in three independent locations so that it survives '
      'ordinary handling. The record has not been altered by the application '
      'after that point.';

  List<List<String>> _verificationRows(VerificationReport r) {
    final SignatureCheck? c = r.signatureCheck;
    final List<List<String>> rows = <List<String>>[
      <String>['Verified on', _stamp.format(DateTime.now())],
      <String>['Verdict', _verdictText(r.verdict)],
      <String>['Confidence', '${(r.confidence * 100).round()}%'],
      <String>[
        'Signature check',
        c == null
            ? 'not performed'
            : (c.valid ? 'VALID — ${c.matchedKey?.origin.label}' : 'INVALID')
      ],
      <String>[
        'Stamp fingerprint drift',
        '${r.hammingDistance} of 64 bits '
            '(tolerance ${SecurityService.maxPerceptualHammingDistance})'
      ],
    ];

    if (r.sceneWasChecked) {
      rows.add(<String>[
        'Scene fingerprint drift',
        '${r.sceneTileDistances.length - r.alteredTiles} of '
            '${r.sceneTileDistances.length} tiles match '
            '(tolerance ${SecurityService.maxSceneTileHammingDistance} bits '
            'per tile)'
      ]);
    } else {
      rows.add(<String>[
        'Scene fingerprint drift',
        'Not checked — this frame predates scene protection'
      ]);
    }

    final String? ai = r.aiAnalysis?.error ??
        (r.aiAnalysis?.syntheticScore != null
            ? '${(r.aiAnalysis!.syntheticScore! * 100).round()}% synthetic '
                'likelihood'
            : null);
    rows.add(<String>['AI screening', ai ?? 'not available']);
    return rows;
  }

  String _limitations(VerificationReport r) {
    final StringBuffer b = StringBuffer(
      'The verification described above establishes that the recorded '
      'position, time, device identifier and image fingerprints have not been '
      'altered since the record was signed, and that the signature was '
      'produced by a key held by the device identified in paragraph 2. It does '
      'not, by itself, establish the following, and this certificate should not '
      'be read as asserting them: ',
    );

    b.write(
      '(a) that the satellite position reported by the operating system was '
      'itself accurate; the application rejects positions the operating system '
      'flags as originating from a mock provider, but a device whose operating '
      'system has been modified may report a false position without that flag. ',
    );

    if (!r.sceneWasChecked) {
      b.write(
        '(b) that the photographic content is unaltered; this frame was signed '
        'before scene fingerprinting was introduced, so only the stamp was '
        'covered. ',
      );
    } else {
      b.write(
        '(b) that alterations smaller than the tile resolution of the scene '
        'fingerprint would necessarily be detected. ',
      );
    }

    b.write(
      '(c) that the subject matter depicted is what any party asserts it to be. '
      'The scheme uses a symmetric key, so independent verification requires '
      'access to a device holding that key.',
    );
    return b.toString();
  }

  // -----------------------------------------------------------------------
  // Layout helpers
  // -----------------------------------------------------------------------

  pw.Widget _sectionHead(String text) => pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(bottom: 6),
        padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 6),
        color: PdfColors.grey300,
        child: pw.Text(
          text,
          style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold),
        ),
      );

  pw.Widget _prose(String text) => pw.Text(
        text,
        textAlign: pw.TextAlign.justify,
        style: const pw.TextStyle(fontSize: 9.5, lineSpacing: 2),
      );

  pw.Widget _table(List<List<String>> rows) => pw.TableHelper.fromTextArray(
        border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
        headerCount: 0,
        cellAlignment: pw.Alignment.topLeft,
        columnWidths: <int, pw.TableColumnWidth>{
          0: const pw.FlexColumnWidth(2.2),
          1: const pw.FlexColumnWidth(5),
        },
        cellStyle: const pw.TextStyle(fontSize: 9),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        data: rows,
      );

  pw.Widget _verdictBanner(VerificationReport r) {
    final PdfColor fill = switch (r.verdict) {
      VerificationVerdict.authentic => PdfColors.green50,
      VerificationVerdict.notSigned => PdfColors.amber50,
      VerificationVerdict.error => PdfColors.amber50,
      _ => PdfColors.red50,
    };

    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        color: fill,
        border: pw.Border.all(color: PdfColors.grey700, width: 0.8),
      ),
      child: pw.Text(r.reason,
          style: const pw.TextStyle(fontSize: 9.5, lineSpacing: 2)),
    );
  }

  pw.Widget _signatureBlock(String heading, CertificateParticulars p) =>
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey700, width: 0.8),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            pw.Text(heading,
                style:
                    pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 10),
            _signatureLine('Name', p.declarantName),
            _signatureLine('Designation', p.declarantDesignation),
            _signatureLine('Address', p.declarantAddress),
            _signatureLine('Date', ''),
            _signatureLine('Signature', ''),
          ],
        ),
      );

  pw.Widget _signatureLine(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 9),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: <pw.Widget>[
            pw.SizedBox(
              width: 80,
              child: pw.Text('$label:',
                  style: const pw.TextStyle(fontSize: 9)),
            ),
            pw.Expanded(
              child: pw.Container(
                decoration: const pw.BoxDecoration(
                  border: pw.Border(
                    bottom: pw.BorderSide(color: PdfColors.grey600, width: 0.6),
                  ),
                ),
                padding: const pw.EdgeInsets.only(bottom: 2),
                child: pw.Text(
                  value.isEmpty ? ' ' : value,
                  style: const pw.TextStyle(fontSize: 9),
                ),
              ),
            ),
          ],
        ),
      );

  static String _orBlank(String s) =>
      s.trim().isEmpty ? '________________________' : s.trim();

  static String _verdictText(VerificationVerdict v) => switch (v) {
        VerificationVerdict.authentic => 'AUTHENTIC',
        VerificationVerdict.tamperedScene => 'PHOTOGRAPHIC CONTENT ALTERED',
        VerificationVerdict.tamperedPixels => 'STAMP ALTERED',
        VerificationVerdict.tamperedMetadata => 'SIGNATURE MISMATCH',
        VerificationVerdict.notSigned => 'NOT SIGNED BY VERIPIC',
        VerificationVerdict.error => 'VERIFICATION INCOMPLETE',
      };

  static pw.MemoryImage? _tryDecode(Uint8List bytes) {
    try {
      return pw.MemoryImage(bytes);
    } catch (_) {
      return null;
    }
  }
}
