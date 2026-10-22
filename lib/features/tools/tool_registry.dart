import 'package:flutter/material.dart';

import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/tooling/inputs.dart';
import '../batch/batch_screen.dart';
import '../editor/editor_screen.dart';
import '../image/image_tools.dart';
import '../image/photo_editor_screen.dart';
import '../organize/organize_screen.dart';
import '../passport/passport_screen.dart';
import '../pdf/convert_tools.dart';
import '../pdf/fill_form_screen.dart';
import '../pdf/organize_tools.dart';
import '../pdf/security_tools.dart';
import '../signature/signature_studio_screen.dart';
import '../smartfix/smart_fix_screen.dart';

enum ToolCategory {
  organize('Organize PDF'),
  edit('Edit & sign'),
  convert('Convert'),
  optimize('Optimize'),
  security('Security & privacy'),
  photo('Photo studio'),
  smart('Smart tools');

  const ToolCategory(this.label);
  final String label;
}

class ToolDef {
  const ToolDef({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.category,
    required this.build,
    this.tone = Tone.primary,
    this.keywords = const [],
    this.accepts = const {},
  });

  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final ToolCategory category;
  final Tone tone;
  final List<String> keywords;

  /// File kinds this tool can take as input (for "Continue with…").
  final Set<FileKind> accepts;
  final Widget Function(List<InputFile> inputs) build;

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final hay = [title, subtitle, category.label, ...keywords].join(' ').toLowerCase();
    return q.split(RegExp(r'\s+')).every(hay.contains);
  }
}

const _pdf = {FileKind.pdf};
const _img = {FileKind.image};

final List<ToolDef> allTools = [
  // Organize
  ToolDef(
    id: 'merge_pdf',
    title: 'Merge PDFs',
    subtitle: 'Combine files into one',
    icon: Icons.call_merge_rounded,
    category: ToolCategory.organize,
    keywords: const ['combine', 'join', 'append'],
    accepts: _pdf,
    build: (i) => MergePdfScreen(initial: i),
  ),
  ToolDef(
    id: 'organize_pdf',
    title: 'Organize pages',
    subtitle: 'Reorder, rotate, delete, insert',
    icon: Icons.grid_view_rounded,
    category: ToolCategory.organize,
    keywords: const ['reorder', 'rotate', 'delete', 'duplicate', 'blank', 'insert', 'crop', 'pages', 'move'],
    accepts: _pdf,
    build: (i) => OrganizeScreen(initial: i),
  ),
  ToolDef(
    id: 'split_pdf',
    title: 'Split PDF',
    subtitle: 'By ranges or every N pages',
    icon: Icons.call_split_rounded,
    category: ToolCategory.organize,
    keywords: const ['separate', 'divide', 'ranges'],
    accepts: _pdf,
    build: (i) => SplitPdfScreen(initial: i),
  ),
  ToolDef(
    id: 'extract_pages',
    title: 'Extract pages',
    subtitle: 'Save selected pages as a new PDF',
    icon: Icons.file_copy_outlined,
    category: ToolCategory.organize,
    keywords: const ['select', 'pages', 'subset'],
    accepts: _pdf,
    build: (i) => SplitPdfScreen(initial: i, extractOnly: true),
  ),
  // Edit & sign
  ToolDef(
    id: 'edit_pdf',
    title: 'Edit & annotate',
    subtitle: 'Text, drawing, highlights, notes',
    icon: Icons.edit_document,
    category: ToolCategory.edit,
    tone: Tone.secondary,
    keywords: const [
      'annotate',
      'highlight',
      'underline',
      'strike',
      'comment',
      'draw',
      'text',
      'image',
      'stamp',
      'note',
    ],
    accepts: _pdf,
    build: (i) => EditorScreen(initial: i),
  ),
  ToolDef(
    id: 'sign_pdf',
    title: 'Sign PDF',
    subtitle: 'Add your signature and date',
    icon: Icons.draw_outlined,
    category: ToolCategory.edit,
    tone: Tone.secondary,
    keywords: const ['signature', 'esign', 'sign'],
    accepts: _pdf,
    build: (i) => EditorScreen(initial: i, mode: EditorMode.sign),
  ),
  ToolDef(
    id: 'fill_form',
    title: 'Fill form',
    subtitle: 'Complete PDF form fields',
    icon: Icons.checklist_rounded,
    category: ToolCategory.edit,
    tone: Tone.secondary,
    keywords: const ['acroform', 'fields', 'application'],
    accepts: _pdf,
    build: (i) => FillFormScreen(initial: i),
  ),
  ToolDef(
    id: 'watermark_pdf',
    title: 'Add watermark',
    subtitle: 'Text or image on every page',
    icon: Icons.water_drop_outlined,
    category: ToolCategory.edit,
    tone: Tone.secondary,
    keywords: const ['stamp', 'confidential', 'draft'],
    accepts: _pdf,
    build: (i) => WatermarkPdfScreen(initial: i),
  ),
  ToolDef(
    id: 'page_numbers',
    title: 'Page numbers',
    subtitle: 'Numbers, header and footer',
    icon: Icons.format_list_numbered_rounded,
    category: ToolCategory.edit,
    tone: Tone.secondary,
    keywords: const ['header', 'footer', 'numbering', 'bates'],
    accepts: _pdf,
    build: (i) => PageNumbersScreen(initial: i),
  ),
  ToolDef(
    id: 'flatten_pdf',
    title: 'Flatten PDF',
    subtitle: 'Lock annotations and fields',
    icon: Icons.layers_clear_outlined,
    category: ToolCategory.edit,
    tone: Tone.secondary,
    keywords: const ['merge annotations', 'lock', 'form'],
    accepts: _pdf,
    build: (i) => FlattenPdfScreen(initial: i),
  ),
  // Convert
  ToolDef(
    id: 'scan',
    title: 'Scan document',
    subtitle: 'Camera to PDF with OCR',
    icon: Icons.document_scanner_outlined,
    category: ToolCategory.convert,
    tone: Tone.tertiary,
    keywords: const ['camera', 'scanner', 'photo', 'paper', 'ocr'],
    build: (i) => const ScanDocumentScreen(),
  ),
  ToolDef(
    id: 'images_to_pdf',
    title: 'Images to PDF',
    subtitle: 'JPG, PNG, WebP to PDF',
    icon: Icons.picture_as_pdf_outlined,
    category: ToolCategory.convert,
    tone: Tone.tertiary,
    keywords: const ['jpg', 'png', 'photo', 'convert', 'webp'],
    accepts: _img,
    build: (i) => ImagesToPdfScreen(initial: i),
  ),
  ToolDef(
    id: 'pdf_to_images',
    title: 'PDF to images',
    subtitle: 'Pages as JPG or PNG',
    icon: Icons.image_outlined,
    category: ToolCategory.convert,
    tone: Tone.tertiary,
    keywords: const ['jpg', 'png', 'export', 'convert'],
    accepts: _pdf,
    build: (i) => PdfToImagesScreen(initial: i),
  ),
  ToolDef(
    id: 'ocr_pdf',
    title: 'Make PDF searchable',
    subtitle: 'Recognise text (OCR)',
    icon: Icons.manage_search_rounded,
    category: ToolCategory.convert,
    tone: Tone.tertiary,
    keywords: const ['ocr', 'text recognition', 'scanned', 'hindi', 'searchable'],
    accepts: {FileKind.pdf, FileKind.image},
    build: (i) => OcrPdfScreen(initial: i),
  ),
  ToolDef(
    id: 'image_to_text',
    title: 'Image to text',
    subtitle: 'Copy text from photos',
    icon: Icons.text_snippet_outlined,
    category: ToolCategory.convert,
    tone: Tone.tertiary,
    keywords: const ['ocr', 'extract', 'copy text', 'hindi'],
    accepts: _img,
    build: (i) => ImageToTextScreen(initial: i),
  ),
  ToolDef(
    id: 'pdf_to_text',
    title: 'PDF to text',
    subtitle: 'Extract text to .txt',
    icon: Icons.notes_rounded,
    category: ToolCategory.convert,
    tone: Tone.tertiary,
    keywords: const ['txt', 'extract', 'copy'],
    accepts: _pdf,
    build: (i) => PdfToTextScreen(initial: i),
  ),
  ToolDef(
    id: 'text_to_pdf',
    title: 'Text to PDF',
    subtitle: 'Typed or .txt to PDF',
    icon: Icons.text_fields_rounded,
    category: ToolCategory.convert,
    tone: Tone.tertiary,
    keywords: const ['txt', 'write', 'notes'],
    accepts: {FileKind.text},
    build: (i) => TextToPdfScreen(initial: i),
  ),
  // Optimize
  ToolDef(
    id: 'compress_pdf',
    title: 'Compress PDF',
    subtitle: 'Smaller files, preview the result',
    icon: Icons.compress_rounded,
    category: ToolCategory.optimize,
    keywords: const ['reduce', 'size', 'shrink', 'optimize', 'kb', 'mb'],
    accepts: _pdf,
    build: (i) => CompressPdfScreen(initial: i),
  ),
  ToolDef(
    id: 'compress_image',
    title: 'Compress images',
    subtitle: 'To a KB or MB limit',
    icon: Icons.photo_size_select_small_rounded,
    category: ToolCategory.optimize,
    keywords: const ['reduce', 'kb', 'size', 'shrink', 'form upload'],
    accepts: _img,
    build: (i) => ImageBatchScreen(kind: ImageToolKind.compress, initial: i),
  ),
  // Security
  ToolDef(
    id: 'protect_pdf',
    title: 'Protect PDF',
    subtitle: 'Password and permissions',
    icon: Icons.lock_outline_rounded,
    category: ToolCategory.security,
    tone: Tone.neutral,
    keywords: const ['password', 'encrypt', 'aes', 'lock', 'change password'],
    accepts: _pdf,
    build: (i) => ProtectPdfScreen(initial: i),
  ),
  ToolDef(
    id: 'unlock_pdf',
    title: 'Remove password',
    subtitle: 'With the password you know',
    icon: Icons.lock_open_rounded,
    category: ToolCategory.security,
    tone: Tone.neutral,
    keywords: const ['decrypt', 'unlock', 'password'],
    accepts: _pdf,
    build: (i) => UnlockPdfScreen(initial: i),
  ),
  ToolDef(
    id: 'redact_pdf',
    title: 'Redact',
    subtitle: 'Permanently remove content',
    icon: Icons.format_color_fill_rounded,
    category: ToolCategory.security,
    tone: Tone.danger,
    keywords: const ['black out', 'hide', 'censor', 'privacy', 'remove text'],
    accepts: _pdf,
    build: (i) => EditorScreen(initial: i, mode: EditorMode.redact),
  ),
  ToolDef(
    id: 'pdf_metadata',
    title: 'PDF metadata',
    subtitle: 'View, edit or remove',
    icon: Icons.info_outline_rounded,
    category: ToolCategory.security,
    tone: Tone.neutral,
    keywords: const ['author', 'properties', 'privacy', 'title'],
    accepts: _pdf,
    build: (i) => PdfMetadataScreen(initial: i),
  ),
  ToolDef(
    id: 'image_metadata',
    title: 'Photo metadata',
    subtitle: 'Remove EXIF and GPS',
    icon: Icons.location_off_outlined,
    category: ToolCategory.security,
    tone: Tone.neutral,
    keywords: const ['exif', 'gps', 'location', 'privacy', 'camera'],
    accepts: _img,
    build: (i) => ImageBatchScreen(kind: ImageToolKind.metadata, initial: i),
  ),
  // Photo
  ToolDef(
    id: 'resize_image',
    title: 'Resize images',
    subtitle: 'Pixels or percentage',
    icon: Icons.photo_size_select_large_rounded,
    category: ToolCategory.photo,
    tone: Tone.tertiary,
    keywords: const ['dimensions', 'pixels', 'scale', 'width', 'height'],
    accepts: _img,
    build: (i) => ImageBatchScreen(kind: ImageToolKind.resize, initial: i),
  ),
  ToolDef(
    id: 'convert_image',
    title: 'Convert images',
    subtitle: 'JPG, PNG, WebP',
    icon: Icons.swap_horiz_rounded,
    category: ToolCategory.photo,
    tone: Tone.tertiary,
    keywords: const ['format', 'jpg', 'png', 'webp'],
    accepts: _img,
    build: (i) => ImageBatchScreen(kind: ImageToolKind.convert, initial: i),
  ),
  ToolDef(
    id: 'photo_editor',
    title: 'Photo editor',
    subtitle: 'Crop, rotate, adjust',
    icon: Icons.tune_rounded,
    category: ToolCategory.photo,
    tone: Tone.tertiary,
    keywords: const ['crop', 'rotate', 'flip', 'brightness', 'contrast', 'saturation', 'sharpen'],
    accepts: _img,
    build: (i) => PhotoEditorScreen(initial: i),
  ),
  ToolDef(
    id: 'background',
    title: 'Change background',
    subtitle: 'Portrait cut-out, transparent PNG',
    icon: Icons.person_outline_rounded,
    category: ToolCategory.photo,
    tone: Tone.tertiary,
    keywords: const ['remove background', 'transparent', 'cutout'],
    accepts: _img,
    build: (i) => PhotoEditorScreen(initial: i, backgroundMode: true),
  ),
  ToolDef(
    id: 'watermark_image',
    title: 'Watermark photos',
    subtitle: 'Text on your images',
    icon: Icons.branding_watermark_outlined,
    category: ToolCategory.photo,
    tone: Tone.tertiary,
    keywords: const ['copyright', 'text', 'overlay'],
    accepts: _img,
    build: (i) => ImageBatchScreen(kind: ImageToolKind.watermark, initial: i),
  ),
  ToolDef(
    id: 'passport_photo',
    title: 'Passport & ID photo',
    subtitle: 'Sizes, background, print sheet',
    icon: Icons.portrait_rounded,
    category: ToolCategory.photo,
    tone: Tone.tertiary,
    keywords: const ['visa', 'id', 'application', 'form photo', '35x45', '2x2'],
    accepts: _img,
    build: (i) => PassportPhotoScreen(initial: i),
  ),
  ToolDef(
    id: 'signature_studio',
    title: 'Signature studio',
    subtitle: 'Draw, clean, resize, KB limit',
    icon: Icons.gesture_rounded,
    category: ToolCategory.photo,
    tone: Tone.tertiary,
    keywords: const ['signature', 'sign', 'transparent', 'kb', 'form'],
    accepts: _img,
    build: (i) => SignatureStudioScreen(initial: i),
  ),
  // Smart
  ToolDef(
    id: 'smart_fix',
    title: 'Smart File Fix',
    subtitle: 'Get a file that meets the rules',
    icon: Icons.auto_awesome_rounded,
    category: ToolCategory.smart,
    keywords: const ['requirements', 'size limit', 'application', 'portal', 'kb', 'convert'],
    accepts: {FileKind.pdf, FileKind.image},
    build: (i) => SmartFixScreen(initial: i),
  ),
  ToolDef(
    id: 'batch',
    title: 'Batch workflow',
    subtitle: 'Resize, compress, rename many photos',
    icon: Icons.dynamic_feed_rounded,
    category: ToolCategory.smart,
    keywords: const ['bulk', 'many', 'presets', 'rename', 'multiple'],
    accepts: _img,
    build: (i) => BatchScreen(initial: i),
  ),
];

ToolDef? toolById(String id) => allTools.where((t) => t.id == id).firstOrNull;

List<ToolDef> searchTools(String query) => allTools.where((t) => t.matches(query)).toList();
