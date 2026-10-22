import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../files/file_kind.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.padding});
  final String title;
  final Widget? action;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(Gaps.page, Gaps.xl, Gaps.page - 8, Gaps.s),
      child: Row(
        children: [
          Expanded(
            child: Semantics(header: true, child: Text(title, style: t.titleMedium)),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Visual tone for a tool or category.
enum Tone { primary, secondary, tertiary, neutral, danger }

({Color bg, Color fg}) toneColors(ColorScheme s, Tone tone) => switch (tone) {
  Tone.primary => (bg: s.primaryContainer, fg: s.onPrimaryContainer),
  Tone.secondary => (bg: s.secondaryContainer, fg: s.onSecondaryContainer),
  Tone.tertiary => (bg: s.tertiaryContainer, fg: s.onTertiaryContainer),
  Tone.neutral => (bg: s.surfaceContainerHighest, fg: s.onSurfaceVariant),
  Tone.danger => (bg: s.errorContainer, fg: s.onErrorContainer),
};

class ToneIcon extends StatelessWidget {
  const ToneIcon(this.icon, {super.key, this.tone = Tone.primary, this.size = 44});
  final IconData icon;
  final Tone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = toneColors(Theme.of(context).colorScheme, tone);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(size * 0.32)),
      child: Icon(icon, color: c.fg, size: size * 0.5),
    );
  }
}

/// Compact tool entry used in grids.
class ToolTile extends StatelessWidget {
  const ToolTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.tone = Tone.primary,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Tone tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gaps.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ToneIcon(icon, tone: tone, size: 40),
              const SizedBox(height: Gaps.m),
              Text(title, style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gaps.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(color: s.surfaceContainerHigh, shape: BoxShape.circle),
              child: Icon(icon, size: 32, color: s.onSurfaceVariant),
            ),
            const SizedBox(height: Gaps.l),
            Text(title, style: t.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: Gaps.s),
              Text(
                message!,
                style: t.bodyMedium!.copyWith(color: s.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[const SizedBox(height: Gaps.xl), action!],
          ],
        ),
      ),
    );
  }
}

enum BannerKind { info, warning, error, success }

/// Inline message box for limitations, warnings and errors.
class MessageBanner extends StatelessWidget {
  const MessageBanner({super.key, required this.message, this.kind = BannerKind.info, this.title, this.action});

  final String message;
  final String? title;
  final BannerKind kind;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final (bg, fg, icon) = switch (kind) {
      BannerKind.info => (
        s.secondaryContainer.withValues(alpha: 0.55),
        s.onSecondaryContainer,
        Icons.info_outline_rounded,
      ),
      BannerKind.warning => (
        const Color(0xFFFFF4D6).withValues(alpha: s.brightness == Brightness.dark ? 0.14 : 1),
        s.brightness == Brightness.dark ? const Color(0xFFFFD98A) : const Color(0xFF6B4A00),
        Icons.warning_amber_rounded,
      ),
      BannerKind.error => (s.errorContainer, s.onErrorContainer, Icons.error_outline_rounded),
      BannerKind.success => (
        s.primaryContainer.withValues(alpha: 0.6),
        s.onPrimaryContainer,
        Icons.check_circle_outline_rounded,
      ),
    };
    return Semantics(
      liveRegion: kind == BannerKind.error,
      child: Container(
        padding: const EdgeInsets.all(Gaps.l),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.m)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: fg, size: 22),
            const SizedBox(width: Gaps.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) ...[
                    Text(title!, style: t.titleSmall!.copyWith(color: fg)),
                    const SizedBox(height: 2),
                  ],
                  Text(message, style: t.bodyMedium!.copyWith(color: fg)),
                  if (action != null) ...[const SizedBox(height: Gaps.s), action!],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Square thumbnail: real image preview for images, a document glyph otherwise.
class FileThumb extends StatelessWidget {
  const FileThumb({super.key, required this.name, this.path, this.size = 48});
  final String name;
  final String? path;
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final kind = FileKind.ofName(name);
    final radius = BorderRadius.circular(size * 0.22);
    if (kind == FileKind.image && path != null) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.file(
          File(path!),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
          errorBuilder: (_, _, _) => _glyph(s, kind, radius),
          gaplessPlayback: true,
        ),
      );
    }
    return _glyph(s, kind, radius);
  }

  Widget _glyph(ColorScheme s, FileKind kind, BorderRadius radius) {
    final (icon, bg, fg) = switch (kind) {
      FileKind.pdf => (Icons.picture_as_pdf_rounded, s.errorContainer, s.onErrorContainer),
      FileKind.image => (Icons.image_rounded, s.tertiaryContainer, s.onTertiaryContainer),
      FileKind.text => (Icons.notes_rounded, s.secondaryContainer, s.onSecondaryContainer),
      FileKind.other => (Icons.insert_drive_file_rounded, s.surfaceContainerHighest, s.onSurfaceVariant),
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, borderRadius: radius),
      child: Icon(icon, color: fg, size: size * 0.48),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.icon, this.tone = Tone.neutral});
  final String label;
  final IconData? icon;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final c = toneColors(Theme.of(context).colorScheme, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: c.fg), const SizedBox(width: 4)],
          Text(label, style: Theme.of(context).textTheme.labelMedium!.copyWith(color: c.fg)),
        ],
      ),
    );
  }
}

/// A titled group of settings/options inside a tool screen.
class OptionGroup extends StatelessWidget {
  const OptionGroup({super.key, required this.title, required this.children, this.subtitle});
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gaps.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.titleSmall),
          if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: t.bodySmall)],
          const SizedBox(height: Gaps.m),
          ...children,
        ],
      ),
    );
  }
}

/// Slider with a visible value label.
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.format,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double)? format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final text = format?.call(value) ?? value.round().toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: t.bodyMedium)),
            Text(text, style: t.labelLarge),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: text,
          semanticFormatterCallback: (_) => '$label $text',
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// A row of label/value pairs.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: t.bodyMedium!.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          Expanded(child: SelectableText(value, style: t.bodyMedium)),
        ],
      ),
    );
  }
}

void showMessage(BuildContext context, String message, {SnackBarAction? action}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), action: action));
}
