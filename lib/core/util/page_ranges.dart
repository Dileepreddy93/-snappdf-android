/// Parses page ranges such as "1-3, 5, 8-" into groups of 0-based indices.
///
/// - "5" is page 5, "2-4" pages 2..4, "8-" page 8 to the end, "-3" pages 1..3.
/// - Reversed ranges ("5-2") are accepted and kept in the given order.
/// Throws [FormatException] with a user-readable message on invalid input.
List<List<int>> parsePageRanges(String input, int pageCount) {
  final text = input.trim();
  if (text.isEmpty) throw const FormatException('Enter page numbers, for example 1-3, 5.');
  final groups = <List<int>>[];
  for (final raw in text.split(RegExp(r'[,;]'))) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    final m = RegExp(r'^(\d*)\s*[-–]\s*(\d*)$').firstMatch(part);
    int start;
    int end;
    if (m != null) {
      if (m.group(1)!.isEmpty && m.group(2)!.isEmpty) {
        throw FormatException('“$part” is not a valid range.');
      }
      start = m.group(1)!.isEmpty ? 1 : int.parse(m.group(1)!);
      end = m.group(2)!.isEmpty ? pageCount : int.parse(m.group(2)!);
    } else if (RegExp(r'^\d+$').hasMatch(part)) {
      start = end = int.parse(part);
    } else {
      throw FormatException('“$part” is not a page number or range.');
    }
    for (final n in [start, end]) {
      if (n < 1 || n > pageCount) {
        throw FormatException('Page $n does not exist (this PDF has $pageCount page${pageCount == 1 ? '' : 's'}).');
      }
    }
    final step = start <= end ? 1 : -1;
    groups.add([for (var i = start; step > 0 ? i <= end : i >= end; i += step) i - 1]);
  }
  if (groups.isEmpty) throw const FormatException('Enter page numbers, for example 1-3, 5.');
  return groups;
}

/// Flattens ranges to a sorted, de-duplicated list of 0-based indices.
List<int> parsePageSelection(String input, int pageCount) {
  final set = <int>{for (final g in parsePageRanges(input, pageCount)) ...g};
  return set.toList()..sort();
}

/// Formats 0-based indices compactly: [0,1,2,4] -> "1-3, 5".
String formatPageSelection(List<int> indices) {
  if (indices.isEmpty) return '';
  final sorted = indices.toSet().toList()..sort();
  final parts = <String>[];
  var start = sorted.first;
  var prev = start;
  for (final i in sorted.skip(1)) {
    if (i == prev + 1) {
      prev = i;
      continue;
    }
    parts.add(start == prev ? '${start + 1}' : '${start + 1}-${prev + 1}');
    start = prev = i;
  }
  parts.add(start == prev ? '${start + 1}' : '${start + 1}-${prev + 1}');
  return parts.join(', ');
}

/// Splits [pageCount] pages into chunks of [size].
List<List<int>> chunkPages(int pageCount, int size) {
  if (size < 1) throw const FormatException('Pages per file must be at least 1.');
  return [
    for (var s = 0; s < pageCount; s += size) [for (var i = s; i < (s + size).clamp(0, pageCount); i++) i],
  ];
}
