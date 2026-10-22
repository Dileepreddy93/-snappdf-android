import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is read from android/key.properties (local) or environment
// variables (CI). Neither the keystore nor its passwords are ever committed.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun signingValue(propertyKey: String, envKey: String): String? =
    keystoreProperties.getProperty(propertyKey) ?: System.getenv(envKey)

val releaseStoreFile = signingValue("storeFile", "SNAPPDF_KEYSTORE_PATH")
val hasReleaseSigning = releaseStoreFile != null && file(releaseStoreFile).exists()

android {
    namespace = "com.snappdf.pro"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.snappdf.pro"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = signingValue("storePassword", "SNAPPDF_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "SNAPPDF_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "SNAPPDF_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Unsigned-by-release-key builds fall back to the debug key so that
            // `flutter run --release` works locally. Such builds must never be
            // uploaded to Play; the release workflow fails if signing is absent.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        resources {
            excludes += setOf("META-INF/DEPENDENCIES", "META-INF/LICENSE*", "META-INF/NOTICE*")
        }
    }

    androidResources {
        // Fonts are memory-mapped by PDFBox; keep them uncompressed.
        noCompress += "ttf"
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // PDF manipulation (Apache-2.0). BouncyCastle is only needed for public-key
    // security handlers / CMS signatures, which this app does not use.
    implementation("com.tom-roush:pdfbox-android:2.0.27.0") {
        exclude(group = "org.bouncycastle")
    }
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("androidx.exifinterface:exifinterface:1.4.2")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.print:print:1.1.0")

    // On-device ML (Google ML Kit, free for commercial use under the ML Kit terms).
    // Text recognition models are bundled so OCR works fully offline.
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
    implementation("com.google.mlkit:segmentation-selfie:16.0.0-beta6")
    // The document scanner UI is delivered by Google Play services.
    implementation("com.google.android.gms:play-services-mlkit-document-scanner:16.0.0")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:rules:1.7.0")
}

// Flutter's integration_test plugin brings old androidx.test artifacts onto the
// app classpath; align everything on current releases.
configurations.configureEach {
    resolutionStrategy {
        force(
            "androidx.test:runner:1.7.0",
            "androidx.test:rules:1.7.0",
            "androidx.test:core:1.7.0",
            "androidx.test:monitor:1.8.0",
        )
    }
}
