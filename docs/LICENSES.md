# Third-party licences

All dependencies were reviewed for commercial, closed-source distribution. No GPL/AGPL code is included.

| Component | Used for | Licence | Notes |
|---|---|---|---|
| Flutter / Dart SDK | App framework | BSD-3-Clause | |
| flutter_riverpod 3.4.3 | State management | MIT | |
| go_router 18.0.2 | Navigation | BSD-3-Clause | |
| pdfrx 2.6.5 (+ pdfrx_engine, pdfium_flutter, pdfium_dart) | PDF viewing, text search, thumbnails | MIT | Bundles PDFium binaries (BSD-3-Clause / Apache-2.0) |
| image 4.10.1 | Image decode/encode/processing | MIT | |
| path_provider, path, intl, crypto, collection, uuid | Utilities | BSD-3-Clause / MIT | |
| pdfbox-android 2.0.27.0 (Tom Roush) | PDF manipulation | Apache-2.0 | BouncyCastle dependency excluded (not used) |
| AndroidX (core, exifinterface, documentfile, print) | Android integration | Apache-2.0 | |
| kotlinx-coroutines | Async native work | Apache-2.0 | |
| Google ML Kit text recognition (Latin, Devanagari), selfie segmentation | On-device OCR, background detection | ML Kit Terms of Service (free, proprietary) | Models bundled; ML Kit telemetry cannot reach the network because the app has no INTERNET permission |
| Google Play services ML Kit document scanner | Document scanning UI | Google APIs Terms of Service (free, proprietary) | Delivered by Play services |
| Inter font | UI typography | SIL Open Font License 1.1 | `assets/fonts/Inter-LICENSE.txt` |
| Noto Sans, Noto Sans Devanagari, Noto Sans Telugu | Fonts embedded into PDFs | SIL Open Font License 1.1 | `android/app/src/main/assets/fonts/OFL.txt` |

## Rejected options
- **MuPDF, iText**: AGPL-3.0. Using them in a closed-source app requires a commercial licence.
- **Syncfusion Flutter PDF**: proprietary community licence with revenue and headcount limits. Usable only if the owner accepts those terms; not adopted without that decision.
- **LibreOffice-based Office conversion**: MPL, but impractically large for a mobile app and not offline-friendly at acceptable size.

The in-app licence page (Settings → Open-source licences) lists Dart package licences automatically.
