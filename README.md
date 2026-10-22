# SnapPDF

Offline, privacy-first PDF, photo and document tools for Android. Built with Flutter 3.47.7 and a Kotlin processing engine.

All processing runs on the device. The release app declares **no internet permission** and **no storage permissions**: files come in and go out through the Android Storage Access Framework, Share and Print, only when the user chooses.

**Status: beta.** See [Release readiness](#release-readiness).

## Features

| Area | What works |
|---|---|
| PDF viewer | Zoom, page navigation, go-to-page, text search with highlights, text selection, share, print |
| Organize | Merge; split by ranges / every N pages / every page; extract pages; visual organizer with reorder (drag), rotate, duplicate, delete, crop, insert blank pages, insert pages from other PDFs or images; undo/redo |
| Edit & sign | Add text, freehand drawing, highlight/underline/strikeout, comments, images, stamps, date, signatures (move/resize/rotate); undo/redo; save as annotations or flattened; fill AcroForm forms; flatten forms and annotations; watermarks (text/image); page numbers, headers, footers |
| Security | AES-256 password protection with permissions; change password; remove password (requires the password, and the owner password if changes are restricted); owner restrictions are enforced; PDF metadata view/edit/remove; **permanent redaction** (see below) |
| Convert | Images → PDF (original JPEGs embedded without recompression, EXIF orientation honoured); PDF → JPG/PNG; text/.txt → PDF; PDF → text; OCR to searchable PDF (from images or scanned PDFs); image → text |
| Scan | Google ML Kit document scanner (edge detection, perspective correction, cleanup filters, multi-page) → PDF, optionally searchable; photo fallback when the scanner is unavailable |
| Compress | PDF presets (high quality / balanced / smallest), custom maximum size with closest-achievable fallback, grayscale, metadata removal, before/after size and rendered preview, batch |
| Photo studio | Compress to KB/MB limit, resize (fit/fill/stretch/pad, px or %), convert JPG/PNG/WebP, crop/rotate/flip, brightness/contrast/saturation/sharpness with before/after, text watermarks, lossless EXIF/GPS removal, portrait background replacement / transparent PNG |
| Signatures | Draw or import (paper background removal), ink colour, exact pixel size, KB limit, transparent PNG or white JPG, private library encrypted with the Android Keystore |
| Passport & ID photo | Common presets plus custom mm/px, background colour, face guide, KB limit, 4×6 in / A4 print sheet (JPG and exact-size PDF) |
| Smart File Fix | Describe the required format, size, dimensions and pages; SnapPDF plans and runs the steps and verifies every constraint |
| Batch | Resize → compress → convert → rename → export for many photos, reusable presets, per-file errors, retry failed, cancellation |
| Files | Recent, favourites, virtual folders, search, sort, filters, rename, duplicate, move/copy, trash with restore (30 days), duplicate detection (SHA-256), details and processing history, share, print, save to device, batch selection, "Open with" / "Share to SnapPDF" |

### Redaction
Redaction is real removal: each page with a marked area is re-rendered with the areas painted black, and the page content is replaced by that image. Form-field values, annotations and tagged-PDF text on those pages are removed as well. The result is verified (no extractable text may remain on redacted pages) before it is saved. Trade-off: redacted pages are no longer text-searchable.

### Signatures
Signatures placed with SnapPDF are visual images, **not** cryptographic digital signatures. The app says so when you save a signed document.

## Known limitations
- Existing text in a PDF cannot be edited (only added, covered by redaction, or annotated).
- No DOCX/XLSX/PPTX ↔ PDF or PDF → HTML conversion. No permissively licensed, offline, high-fidelity Office engine is available for Android, so these are not offered rather than offered with poor fidelity.
- OCR supports Latin and Devanagari (Hindi). **Telugu is not supported** by the on-device engine (ML Kit); the app states this.
- Visible text in Indic scripts added to PDFs is not shaped (conjuncts may render incorrectly). Invisible OCR text layers are unaffected.
- Digital certificate signing and signature validation are not implemented.
- Dynamic XFA forms cannot be filled.
- Background replacement works for portraits (people) only.
- The document scanner requires Google Play services.
- The UI is English only.

## Architecture
```
lib/
  app/        theme (Material 3, Inter), router (go_router), shell
  core/       design system, native bridge (typed MethodChannel API), private workspace,
              file library (atomic JSON index), settings, jobs (progress/cancel), tooling
              (universal flow: inputs -> options -> process -> verify -> save/share/continue)
  features/   one folder per area (pdf, organize, editor, viewer, image, signature,
              passport, smartfix, batch, files, settings, home, tools)
android/app/src/main/kotlin/com/snappdf/pro/
  pdf/        PDFBox-Android engine: pages, stamping, security, compression, raster,
              redaction, edits, forms, creation, geometry (display <-> PDF space)
  ml/         ML Kit OCR + searchable PDF, selfie segmentation
  io/         SAF import/export, print, Keystore-encrypted secure store
  bridge/     method channel dispatch, job registry, progress events, error codes
```
State management: Riverpod. Image processing: pure Dart (`image` package) in isolates. PDF writing: PDFBox-Android. PDF viewing: pdfrx (PDFium).

## Build
Requirements: Flutter 3.47.7, JDK 21, Android SDK 36.

```bash
flutter pub get
flutter analyze
flutter test                       # Dart unit + widget tests
flutter build apk --debug
cd android && ./gradlew :app:testDebugUnitTest            # Kotlin JVM tests
cd android && ./gradlew :app:connectedDebugAndroidTest    # engine tests (device/emulator)
flutter test integration_test      # end-to-end flows (device/emulator)
```

Release builds: see [docs/RELEASE.md](docs/RELEASE.md).

## Release readiness
Beta. Automated tests cover the engines and UI and device tests run on an Android emulator, but the app has not yet been validated on physical devices across manufacturers, screen sizes and Android versions, and has no Play Store listing assets or privacy policy URL. A debug APK is a testing build, not a release.

Licences of all dependencies: [docs/LICENSES.md](docs/LICENSES.md).
