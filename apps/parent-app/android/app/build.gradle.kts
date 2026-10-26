import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Secrets and signing material come from android/local.properties (gitignored) or the environment.
// Nothing here is committed; CI injects them from repository secrets (docs/test-guides/PUBLISHING-READINESS.md).
val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun secret(name: String): String? = (localProps.getProperty(name) ?: System.getenv(name))?.takeIf { it.isNotBlank() }
val mapsApiKey = secret("MAPS_API_KEY") ?: ""
val releaseStoreFile = secret("OSRA_UPLOAD_KEYSTORE")

// #400 / #317: Firebase config is never committed. Without google-services.json the plugin must not be
// applied — applying it unconditionally makes `:app:processDebugGoogleServices` fail the build — so the
// build stays green and push is simply absent, which is what `FcmPushTokenSource` reports.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "dev.familyshield.familyshield_parent"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // `flutter_local_notifications` 21 uses java.time, which needs the desugared
        // library on minSdk < 26. Without this the release build fails at
        // `:app:checkReleaseAarMetadata` with "requires core library desugaring" —
        // and `flutter test` never builds the bundle, so the suite cannot catch it
        // (#395 review).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.familyshield.familyshield_parent"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["MAPS_API_KEY"] = mapsApiKey
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("upload") {
                storeFile = rootProject.file(releaseStoreFile)
                storePassword = secret("OSRA_UPLOAD_KEYSTORE_PASSWORD")
                keyAlias = secret("OSRA_UPLOAD_KEY_ALIAS") ?: "upload"
                keyPassword = secret("OSRA_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Real upload key when OSRA_UPLOAD_KEYSTORE is configured; debug key otherwise so
            // `flutter run --release` keeps working on a dev box. CI fails the release job if the
            // upload key is missing (see .github/workflows/ci.yml).
            signingConfig = if (releaseStoreFile != null) signingConfigs.getByName("upload") else signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Pairs with isCoreLibraryDesugaringEnabled above (#395 review).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
