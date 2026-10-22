import 'dart:async';

import 'package:flutter/services.dart';

/// Error raised by native processing, with a stable [code] from
/// android/app/src/main/kotlin/com/snappdf/pro/OpError.kt.
class NativeError implements Exception {
  NativeError(this.code, this.message);

  final String code;
  final String message;

  static const passwordRequired = 'PASSWORD_REQUIRED';
  static const wrongPassword = 'WRONG_PASSWORD';
  static const invalidFile = 'INVALID_FILE';
  static const unsupported = 'UNSUPPORTED';
  static const io = 'IO';
  static const cancelled = 'CANCELLED';
  static const outOfMemory = 'OUT_OF_MEMORY';
  static const tooLarge = 'TOO_LARGE';
  static const unavailable = 'UNAVAILABLE';
  static const restricted = 'RESTRICTED';
  static const badArgs = 'BAD_ARGS';

  bool get isCancelled => code == cancelled;
  bool get needsPassword => code == passwordRequired || code == wrongPassword || code == restricted;

  @override
  String toString() => message;
}

class JobProgress {
  const JobProgress(this.jobId, this.done, this.total, this.message);
  final String jobId;
  final int done;
  final int total;
  final String? message;
  double? get fraction => total > 0 ? (done / total).clamp(0, 1) : null;
}

class PdfPageSize {
  const PdfPageSize(this.width, this.height, this.rotation);
  final double width;
  final double height;
  final int rotation;
}

class PdfMetadata {
  const PdfMetadata({
    this.title,
    this.author,
    this.subject,
    this.keywords,
    this.creator,
    this.producer,
    this.created,
    this.modified,
    this.hasXmp = false,
  });

  final String? title;
  final String? author;
  final String? subject;
  final String? keywords;
  final String? creator;
  final String? producer;
  final DateTime? created;
  final DateTime? modified;
  final bool hasXmp;

  bool get isEmpty =>
      [title, author, subject, keywords, creator, producer].every((v) => v == null || v.isEmpty) &&
      created == null &&
      modified == null &&
      !hasXmp;

  Map<String, Object?> toArgs() => {
    'title': title,
    'author': author,
    'subject': subject,
    'keywords': keywords,
    'creator': creator,
    'producer': producer,
  };
}

class PdfInfo {
  PdfInfo({
    required this.pageCount,
    required this.encrypted,
    required this.pages,
    required this.fileSize,
    required this.hasForm,
    required this.hasXfa,
    required this.hasText,
    required this.metadata,
  });

  final int pageCount;
  final bool encrypted;
  final List<PdfPageSize> pages;
  final int fileSize;
  final bool hasForm;
  final bool hasXfa;
  final bool hasText;
  final PdfMetadata metadata;

  factory PdfInfo.fromMap(Map<Object?, Object?> m) {
    final meta = (m['metadata'] as Map?) ?? const {};
    DateTime? date(Object? v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
    return PdfInfo(
      pageCount: m['pageCount'] as int,
      encrypted: m['encrypted'] as bool? ?? false,
      pages: [
        for (final p in (m['pages'] as List? ?? const []))
          PdfPageSize(
            ((p as Map)['width'] as num).toDouble(),
            (p['height'] as num).toDouble(),
            p['rotation'] as int? ?? 0,
          ),
      ],
      fileSize: (m['fileSize'] as num?)?.toInt() ?? 0,
      hasForm: m['hasForm'] as bool? ?? false,
      hasXfa: m['hasXfa'] as bool? ?? false,
      hasText: m['hasText'] as bool? ?? true,
      metadata: PdfMetadata(
        title: meta['title'] as String?,
        author: meta['author'] as String?,
        subject: meta['subject'] as String?,
        keywords: meta['keywords'] as String?,
        creator: meta['creator'] as String?,
        producer: meta['producer'] as String?,
        created: date(meta['created']),
        modified: date(meta['modified']),
        hasXmp: meta['hasXmp'] as bool? ?? false,
      ),
    );
  }
}

class PickedFile {
  const PickedFile(this.path, this.name, this.size, this.mime);
  final String path;
  final String name;
  final int size;
  final String mime;

  factory PickedFile.fromMap(Map<Object?, Object?> m) => PickedFile(
    m['path'] as String,
    m['name'] as String,
    (m['size'] as num).toInt(),
    m['mime'] as String? ?? 'application/octet-stream',
  );
}

class CompressResult {
  const CompressResult(this.inputBytes, this.outputBytes, this.imagesRecompressed, this.imagesKept, this.pageCount);
  final int inputBytes;
  final int outputBytes;
  final int imagesRecompressed;
  final int imagesKept;
  final int pageCount;
}

class OcrLine {
  const OcrLine(this.text, this.left, this.top, this.right, this.bottom);
  final String text;
  final int left;
  final int top;
  final int right;
  final int bottom;
}

class OcrResult {
  const OcrResult(this.text, this.width, this.height, this.lines);
  final String text;
  final int width;
  final int height;
  final List<OcrLine> lines;
}

class PdfFormField {
  const PdfFormField({
    required this.name,
    required this.label,
    required this.type,
    required this.value,
    required this.options,
    required this.readOnly,
    required this.required,
    required this.multiline,
    required this.maxLength,
    required this.multiSelect,
    required this.page,
  });

  final String name;
  final String label;

  /// text, checkbox, radio, combo, list, signature
  final String type;
  final Object? value;
  final List<String> options;
  final bool readOnly;
  final bool required;
  final bool multiline;
  final int? maxLength;
  final bool multiSelect;
  final int? page;

  factory PdfFormField.fromMap(Map<Object?, Object?> m) => PdfFormField(
    name: m['name'] as String,
    label: (m['label'] as String?) ?? (m['name'] as String),
    type: m['type'] as String,
    value: m['value'],
    options: [for (final o in (m['options'] as List? ?? const [])) '$o'],
    readOnly: m['readOnly'] as bool? ?? false,
    required: m['required'] as bool? ?? false,
    multiline: m['multiline'] as bool? ?? false,
    maxLength: m['maxLength'] as int?,
    multiSelect: m['multiSelect'] as bool? ?? false,
    page: m['page'] as int?,
  );
}

/// Typed access to the Kotlin engine (see NativeBridge.kt).
///
/// Every long-running call accepts a [jobId] so progress events can be
/// matched and the job can be cancelled with [cancel].
class NativeApi {
  NativeApi({MethodChannel? channel, EventChannel? progressChannel})
    : _channel = channel ?? const MethodChannel('com.snappdf.pro/native'),
      _progressChannel = progressChannel ?? const EventChannel('com.snappdf.pro/progress');

  final MethodChannel _channel;
  final EventChannel _progressChannel;
  Stream<JobProgress>? _progress;
  void Function()? onIncomingAvailable;

  void attachIncomingHandler() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'incomingAvailable') onIncomingAvailable?.call();
      return null;
    });
  }

  Stream<JobProgress> get progress => _progress ??= _progressChannel.receiveBroadcastStream().map((e) {
    final m = e as Map;
    return JobProgress(m['jobId'] as String, m['done'] as int, m['total'] as int, m['message'] as String?);
  }).asBroadcastStream();

  Future<T?> call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw NativeError(e.code, e.message ?? 'Something went wrong.');
    } on MissingPluginException {
      throw NativeError(NativeError.unavailable, 'This feature is not available on this device.');
    }
  }

  Future<void> cancel(String jobId) => call('job.cancel', {'target': jobId});

  // ---------------- Files ----------------

  Future<List<PickedFile>> pickFiles(List<String> mimeTypes, {bool multiple = false}) async {
    final r = await call<List>('io.pickFiles', {'mimeTypes': mimeTypes, 'multiple': multiple});
    return [for (final m in r ?? const []) PickedFile.fromMap(m as Map)];
  }

  /// Returns the destination URI, or null if the user cancelled.
  Future<String?> saveAs(String path, String name, String mime) =>
      call<String>('io.saveAs', {'path': path, 'name': name, 'mime': mime});

  Future<({String uri, String? name})?> pickFolder() async {
    final r = await call<Map>('io.pickFolder');
    if (r == null) return null;
    return (uri: r['uri'] as String, name: r['name'] as String?);
  }

  Future<List<String>> exportToFolder(String treeUri, List<({String path, String name})> files) async {
    final r = await call<List>('io.exportToFolder', {
      'treeUri': treeUri,
      'files': [
        for (final f in files) {'path': f.path, 'name': f.name},
      ],
    });
    return [for (final n in r ?? const []) '$n'];
  }

  Future<void> share(List<String> paths, String mime, {String? title}) =>
      call('io.share', {'paths': paths, 'mime': mime, 'title': title});

  Future<void> printFile(String path, String name) => call('io.print', {'path': path, 'name': name});

  Future<String?> takePhoto() => call<String>('io.camera');

  Future<bool> scannerAvailable() async => await call<bool>('io.scannerAvailable') ?? false;

  Future<List<String>> scanDocument({int pageLimit = 20}) async {
    final r = await call<List>('io.scan', {'pageLimit': pageLimit});
    return [for (final p in r ?? const []) '$p'];
  }

  Future<List<PickedFile>> takeIncoming() async {
    final r = await call<List>('app.takeIncoming');
    return [for (final m in r ?? const []) PickedFile.fromMap(m as Map)];
  }

  Future<void> cleanTemp({Duration maxAge = Duration.zero}) =>
      call('app.cleanTemp', {'maxAgeMs': maxAge.inMilliseconds});

  // ---------------- Secure storage ----------------

  Future<void> secureWrite(String name, Uint8List data) => call('secure.write', {'name': name, 'data': data});
  Future<Uint8List?> secureRead(String name) => call<Uint8List>('secure.read', {'name': name});
  Future<void> secureDelete(String name) => call('secure.delete', {'name': name});
  Future<List<String>> secureList() async => [for (final n in await call<List>('secure.list') ?? const []) '$n'];

  // ---------------- PDF ----------------

  Future<PdfInfo> pdfInfo(String path, {String? password}) async =>
      PdfInfo.fromMap((await call<Map>('pdf.info', {'path': path, 'password': password}))!);

  Future<void> merge(List<({String path, String? password})> sources, String output, {String? jobId}) =>
      call('pdf.merge', {
        'sources': [
          for (final s in sources) {'path': s.path, 'password': s.password},
        ],
        'output': output,
        'jobId': jobId,
      });

  Future<void> assemble(
    List<({String path, String? password})> sources,
    List<Map<String, Object?>> pages,
    String output, {
    String? jobId,
  }) => call('pdf.assemble', {
    'sources': [
      for (final s in sources) {'path': s.path, 'password': s.password},
    ],
    'pages': pages,
    'output': output,
    'jobId': jobId,
  });

  Future<List<String>> extractText(String path, {String? password, List<int>? pages, String? jobId}) async {
    final r = await call<List>('pdf.extractText', {'path': path, 'password': password, 'pages': pages, 'jobId': jobId});
    return [for (final t in r ?? const []) '$t'];
  }

  Future<void> watermark(Map<String, Object?> args) => call('pdf.watermark', args);
  Future<void> pageNumbers(Map<String, Object?> args) => call('pdf.pageNumbers', args);
  Future<void> protect(Map<String, Object?> args) => call('pdf.protect', args);

  Future<void> unlock(String path, String? password, String output) =>
      call('pdf.unlock', {'path': path, 'password': password, 'output': output});

  Future<void> setMetadata(
    String path,
    String? password,
    String output, {
    PdfMetadata? metadata,
    bool removeAll = false,
  }) => call('pdf.setMetadata', {
    'path': path,
    'password': password,
    'output': output,
    'metadata': metadata?.toArgs(),
    'removeAll': removeAll,
  });

  Future<CompressResult> compress(
    String path,
    String? password,
    String output, {
    required int maxDpi,
    required double jpegQuality,
    bool stripMetadata = true,
    bool grayscale = false,
    String? jobId,
  }) async {
    final r = (await call<Map>('pdf.compress', {
      'path': path,
      'password': password,
      'output': output,
      'maxDpi': maxDpi,
      'jpegQuality': jpegQuality,
      'stripMetadata': stripMetadata,
      'grayscale': grayscale,
      'jobId': jobId,
    }))!;
    return CompressResult(
      (r['inputBytes'] as num).toInt(),
      (r['outputBytes'] as num).toInt(),
      r['imagesRecompressed'] as int,
      r['imagesKept'] as int,
      r['pageCount'] as int,
    );
  }

  Future<List<String>> pdfToImages(
    String path,
    String? password, {
    List<int>? pages,
    required double dpi,
    required String format,
    int quality = 90,
    required String outDir,
    required String baseName,
    String? jobId,
  }) async {
    final r = await call<List>('pdf.toImages', {
      'path': path,
      'password': password,
      'pages': pages,
      'dpi': dpi,
      'format': format,
      'quality': quality,
      'outDir': outDir,
      'baseName': baseName,
      'jobId': jobId,
    });
    return [for (final p in r ?? const []) '$p'];
  }

  Future<String> renderPage(String path, String? password, int page, int maxWidth, String output) async {
    final r = await call<Map>('pdf.renderPage', {
      'path': path,
      'password': password,
      'page': page,
      'maxWidth': maxWidth,
      'output': output,
    });
    return r!['path'] as String;
  }

  Future<void> imagesToPdf(
    List<String> images,
    String output, {
    String pageSize = 'a4',
    String orientation = 'auto',
    double margin = 0,
    String quality = 'original',
    double dpi = 300,
    String? jobId,
  }) => call('pdf.imagesToPdf', {
    'dpi': dpi,
    'images': images,
    'output': output,
    'pageSize': pageSize,
    'orientation': orientation,
    'margin': margin,
    'quality': quality,
    'jobId': jobId,
  });

  Future<void> textToPdf(String text, String output, {double fontSize = 11, String pageSize = 'a4', String? jobId}) =>
      call('pdf.textToPdf', {
        'text': text,
        'output': output,
        'fontSize': fontSize,
        'pageSize': pageSize,
        'jobId': jobId,
      });

  Future<({int pagesRedacted, bool verified})> redact(
    String path,
    String? password,
    String output,
    Map<int, List<List<double>>> rects, {
    double dpi = 200,
    bool stripMetadata = true,
    String? jobId,
  }) async {
    final r = (await call<Map>('pdf.redact', {
      'path': path,
      'password': password,
      'output': output,
      'regions': [
        for (final e in rects.entries) {'page': e.key, 'rects': e.value},
      ],
      'dpi': dpi,
      'stripMetadata': stripMetadata,
      'jobId': jobId,
    }))!;
    return (pagesRedacted: r['pagesRedacted'] as int, verified: r['verified'] as bool);
  }

  Future<void> applyEdits(
    String path,
    String? password,
    String output,
    List<Map<String, Object?>> edits, {
    bool flatten = false,
    String? author,
    String? jobId,
  }) => call('pdf.applyEdits', {
    'path': path,
    'password': password,
    'output': output,
    'edits': edits,
    'flatten': flatten,
    'author': author,
    'jobId': jobId,
  });

  Future<({int annotations, int fields})> flatten(String path, String? password, String output, {String? jobId}) async {
    final r = (await call<Map>('pdf.flatten', {'path': path, 'password': password, 'output': output, 'jobId': jobId}))!;
    return (annotations: r['annotations'] as int, fields: r['fields'] as int);
  }

  Future<({List<PdfFormField> fields, bool xfa})> formFields(String path, {String? password}) async {
    final r = (await call<Map>('pdf.formFields', {'path': path, 'password': password}))!;
    return (
      fields: [for (final f in (r['fields'] as List? ?? const [])) PdfFormField.fromMap(f as Map)],
      xfa: r['xfa'] as bool? ?? false,
    );
  }

  Future<void> fillForm(
    String path,
    String? password,
    String output,
    Map<String, Object?> values, {
    bool flatten = false,
  }) => call('pdf.fillForm', {
    'path': path,
    'password': password,
    'output': output,
    'values': values,
    'flatten': flatten,
  });

  // ---------------- OCR / ML ----------------

  Future<OcrResult> recognizeText(String path, {String script = 'latin'}) async {
    final r = (await call<Map>('ocr.recognize', {'path': path, 'script': script}))!;
    final lines = <OcrLine>[];
    for (final b in (r['blocks'] as List? ?? const [])) {
      for (final l in ((b as Map)['lines'] as List? ?? const [])) {
        final box = (l as Map)['box'] as List?;
        if (box == null) continue;
        lines.add(OcrLine(l['text'] as String, box[0] as int, box[1] as int, box[2] as int, box[3] as int));
      }
    }
    return OcrResult(r['text'] as String? ?? '', r['width'] as int? ?? 0, r['height'] as int? ?? 0, lines);
  }

  Future<({int pages, int lines, String text})> imagesToSearchablePdf(
    List<String> images,
    String output, {
    String script = 'latin',
    String pageSize = 'a4',
    String? jobId,
  }) async {
    final r = (await call<Map>('ocr.imagesToPdf', {
      'images': images,
      'output': output,
      'script': script,
      'pageSize': pageSize,
      'jobId': jobId,
    }))!;
    return (pages: r['pages'] as int, lines: r['lines'] as int, text: r['text'] as String? ?? '');
  }

  Future<({int pages, int lines, String text})> ocrPdf(
    String path,
    String? password,
    String output, {
    String script = 'latin',
    bool force = false,
    String? jobId,
  }) async {
    final r = (await call<Map>('ocr.pdf', {
      'path': path,
      'password': password,
      'output': output,
      'script': script,
      'force': force,
      'jobId': jobId,
    }))!;
    return (pages: r['pages'] as int, lines: r['lines'] as int, text: r['text'] as String? ?? '');
  }

  Future<({String path, int width, int height, double coverage})> personMask(String path, String output) async {
    final r = (await call<Map>('ml.personMask', {'path': path, 'output': output}))!;
    return (
      path: r['path'] as String,
      width: r['width'] as int,
      height: r['height'] as int,
      coverage: (r['coverage'] as num).toDouble(),
    );
  }
}
