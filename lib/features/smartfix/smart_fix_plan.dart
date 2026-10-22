import '../../core/files/file_kind.dart';
import '../../core/util/page_ranges.dart';

enum FixTarget {
  same('Keep format'),
  pdf('PDF'),
  jpg('JPG'),
  png('PNG'),
  webp('WebP');

  const FixTarget(this.label);
  final String label;
  bool get isImage => this == jpg || this == png || this == webp;
}

/// What the user wants the file to become.
class FixRequest {
  const FixRequest({
    required this.inputKind,
    this.target = FixTarget.same,
    this.maxBytes,
    this.width,
    this.height,
    this.exactSize = false,
    this.pages = '',
    this.pageCount,
  });

  final FileKind inputKind;
  final FixTarget target;
  final int? maxBytes;
  final int? width;
  final int? height;

  /// Exactly width x height (cropping to fill) instead of fitting inside.
  final bool exactSize;

  /// Page selection for PDF input, e.g. "1-2". Empty = all.
  final String pages;
  final int? pageCount;

  bool get outputIsPdf => target == FixTarget.pdf || (target == FixTarget.same && inputKind == FileKind.pdf);
  bool get outputIsImage => target.isImage || (target == FixTarget.same && inputKind == FileKind.image);

  bool get pdfIn => inputKind == FileKind.pdf;
  bool get imageIn => inputKind == FileKind.image;
}

/// Returns problems that prevent running, in plain language.
List<String> validateFixRequest(FixRequest r) {
  final errors = <String>[];
  if (!r.pdfIn && !r.imageIn) errors.add('Choose a PDF or an image.');
  if (r.maxBytes != null && r.maxBytes! < 1024) errors.add('The size limit must be at least 1 KB.');
  if (r.width != null && r.width! <= 0 || r.height != null && r.height! <= 0) {
    errors.add('Dimensions must be positive.');
  }
  if (r.exactSize && (r.width == null || r.height == null)) {
    errors.add('Enter both width and height for an exact size.');
  }
  if ((r.width ?? 0) * (r.height ?? 0) > 50 * 1000 * 1000) errors.add('The requested dimensions are too large.');
  final dims = r.width != null || r.height != null;
  if (dims && r.outputIsPdf) {
    errors.add('Pixel dimensions apply to images. Choose JPG, PNG or WebP, or remove the dimensions.');
  }
  if (r.pages.trim().isNotEmpty) {
    if (!r.pdfIn) {
      errors.add('Page selection only applies to PDFs.');
    } else if (r.pageCount != null) {
      try {
        parsePageSelection(r.pages, r.pageCount!);
      } on FormatException catch (e) {
        errors.add(e.message);
      }
    }
  }
  return errors;
}

/// Human-readable steps that will run, shown before processing.
List<String> describePlan(FixRequest r) {
  final steps = <String>[];
  final t = r.target;
  if (r.pdfIn && r.pages.trim().isNotEmpty) steps.add('Keep pages ${r.pages.trim()}');
  if (r.pdfIn && t.isImage) steps.add('Render pages as ${t.label} images');
  if (r.imageIn && t == FixTarget.pdf) steps.add('Place the image on a PDF page');
  if (r.imageIn && t.isImage) steps.add('Convert to ${t.label}');
  if (r.width != null || r.height != null) {
    steps.add(
      r.exactSize
          ? 'Resize to exactly ${r.width} × ${r.height} px'
          : 'Fit within ${r.width ?? 'any'} × ${r.height ?? 'any'} px',
    );
  }
  if (r.maxBytes != null) steps.add('Reduce to at most ${formatBytes(r.maxBytes!)}');
  steps.add('Check the result against every requirement');
  return steps;
}
