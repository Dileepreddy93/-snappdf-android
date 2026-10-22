import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.defaultJpegQuality = 88,
    this.authorName = '',
    this.ocrScript = 'latin',
    this.stripPdfMetadata = true,
    this.onboarded = false,
  });

  final ThemeMode themeMode;
  final int defaultJpegQuality;

  /// Written into annotations as the author, if set.
  final String authorName;

  /// Default OCR script: latin or devanagari.
  final String ocrScript;

  /// Remove PDF metadata when compressing.
  final bool stripPdfMetadata;
  final bool onboarded;

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? defaultJpegQuality,
    String? authorName,
    String? ocrScript,
    bool? stripPdfMetadata,
    bool? onboarded,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    defaultJpegQuality: defaultJpegQuality ?? this.defaultJpegQuality,
    authorName: authorName ?? this.authorName,
    ocrScript: ocrScript ?? this.ocrScript,
    stripPdfMetadata: stripPdfMetadata ?? this.stripPdfMetadata,
    onboarded: onboarded ?? this.onboarded,
  );

  Map<String, Object?> toJson() => {
    'themeMode': themeMode.name,
    'defaultJpegQuality': defaultJpegQuality,
    'authorName': authorName,
    'ocrScript': ocrScript,
    'stripPdfMetadata': stripPdfMetadata,
    'onboarded': onboarded,
  };

  factory AppSettings.fromJson(Map<String, Object?> j) => AppSettings(
    themeMode: ThemeMode.values.asNameMap()[j['themeMode']] ?? ThemeMode.system,
    defaultJpegQuality: (j['defaultJpegQuality'] as int? ?? 88).clamp(10, 100),
    authorName: j['authorName'] as String? ?? '',
    ocrScript: j['ocrScript'] as String? ?? 'latin',
    stripPdfMetadata: j['stripPdfMetadata'] as bool? ?? true,
    onboarded: j['onboarded'] as bool? ?? false,
  );
}

/// JSON file persistence with atomic replace.
class JsonFileStore {
  JsonFileStore(this.file);
  final File file;

  Future<Map<String, Object?>?> read() async {
    try {
      if (!await file.exists()) return null;
      return (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> write(Map<String, Object?> data) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(data), flush: true);
    await tmp.rename(file.path);
  }
}
