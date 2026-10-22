# Release process

## 1. Create an upload key (once)
```bash
keytool -genkeypair -v -keystore snappdf-upload.jks -alias upload \
  -keyalg RSA -keysize 4096 -validity 10000
```
Store the keystore and passwords in a password manager. Never commit them (`*.jks` and `key.properties` are git-ignored). Enrol in Play App Signing so Google holds the app signing key and this is only the upload key.

## 2. Local signed build
Create `android/key.properties`:
```
storeFile=/absolute/path/to/snappdf-upload.jks
storePassword=...
keyAlias=upload
keyPassword=...
```
Then:
```bash
flutter build appbundle --release      # build/app/outputs/bundle/release/app-release.aab
flutter build apk --release --split-per-abi
```
Without signing configuration the release build falls back to the debug key so it can be run locally. Such a build must never be uploaded.

## 3. CI signed build
Add repository secrets: `SNAPPDF_KEYSTORE_BASE64` (`base64 -w0 snappdf-upload.jks`), `SNAPPDF_KEYSTORE_PASSWORD`, `SNAPPDF_KEY_ALIAS`, `SNAPPDF_KEY_PASSWORD`.
Push a tag `vX.Y.Z` or run the **Release build** workflow manually. It fails if any secret is missing or if the output is signed with the debug key, then uploads the AAB and APKs as artifacts.

## 4. Before uploading to Play
- Bump `version:` in `pubspec.yaml` (build number must increase).
- The application ID `com.snappdf.pro` is permanent once published. Change it first if needed (`android/app/build.gradle.kts`, Kotlin package).
- Run the full test suite, including `connectedDebugAndroidTest` and `integration_test`, on physical devices.
- Prepare the store listing, screenshots and a privacy policy URL. The Data safety form: no data collected or shared; files processed on device.
- Check that the release manifest has no network or storage permissions (CI does this with `aapt2 dump permissions`).
