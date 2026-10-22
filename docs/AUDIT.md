# Baseline audit (2026-10-22)

## Repository
- `github.com/Dileepreddy93/-snappdf-android` was **empty** (no commits). No earlier starter project was supplied, so nothing existing could be extended, and nothing was overwritten or discarded.
- The working directory `/home/dileep-reddy/snappdf-android` was empty.

## Environment
| Item | Found | Action |
|---|---|---|
| Flutter | not installed | Installed Flutter 3.47.7 (latest stable, 2026-10-08) |
| JDK | JRE 17/21 only (no `javac`) | Installed Temurin JDK 21 |
| Android SDK | platform-tools only | Installed cmdline-tools, platform 36, build-tools 36.0.0, NDK 28.2, CMake 3.22.1, emulator, Android 15 Google Play x86_64 image |
| Device | none attached | KVM available: Android 15 emulator (Pixel 6 profile) used for device tests |
| GitHub | `gh` authenticated as `Dileepreddy93` (admin, `repo` + `workflow` scopes) | Push over HTTPS. The SSH key authenticates as a different account (`Dileepedutinker`), so SSH push was not used |

## Baseline
No existing code, tests, workflows or document-processing modules, so the baseline test result was "no tests". A freshly generated Flutter project built a debug APK successfully, which validated the toolchain.

## Strategy chosen
- Flutter UI + Kotlin engine over a single typed method channel.
- Permissively licensed engines only (see LICENSES.md): PDFBox-Android for writing PDFs, PDFium (pdfrx) for viewing and independent verification, pure-Dart `image` for photos, ML Kit for OCR/scanning/segmentation.
- Offline by construction: no INTERNET permission in release builds.
- Tests at three levels: Dart unit/widget (host), Kotlin JVM + instrumented engine tests (emulator), Flutter integration tests (emulator).
