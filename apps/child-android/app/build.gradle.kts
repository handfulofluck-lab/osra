plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("kotlin-kapt")
    id("com.google.dagger.hilt.android")
    id("com.google.devtools.ksp")
}

/**
 * Roadmap 1.5 (#319): the Google Services plugin turns `app/google-services.json` into the resource
 * values FirebaseApp reads at startup, so without it `FirebaseMessagingService.onNewToken` never runs
 * and the agent never holds a token to publish.
 *
 * Applied conditionally, and outside the `plugins` block, because the plugin fails configuration with
 * `File google-services.json is missing` when that file is absent — and it is absent on CI and in every
 * fresh clone: it carries a Firebase project id and API key, so it is gitignored, never committed. The
 * FCM-free build (poll fallback, §14.2) is the default and must stay buildable; a machine that has the
 * file gets real FCM. The unconditional form is measured in the PR: it fails the build here.
 */
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// Plan 1.8: a real release signing config, read from the environment so no key material ever sits in
// the repo. When the four variables are absent (CI, a tester's machine) the release build falls back
// to the debug key and says so — the APK still installs, it is just not the store key.
val releaseKeystore = System.getenv("OSRA_UPLOAD_KEYSTORE")
val releaseKeystorePassword = System.getenv("OSRA_UPLOAD_KEYSTORE_PASSWORD")
val releaseKeyAlias = System.getenv("OSRA_UPLOAD_KEY_ALIAS")
val releaseKeyPassword = System.getenv("OSRA_UPLOAD_KEY_PASSWORD")
// #412 review: `file()` resolves against the APP module, not the project root, so `OSRA_UPLOAD_KEYSTORE=app/upload.jks`
// (what the CI job exports) was looked up as `app/app/upload.jks` and never found — every "signed" release was
// debug-signed. `rootProject.file()` is what the parent app uses and what the CI path means.
val releaseKeystoreFile = releaseKeystore?.let { rootProject.file(it) }
val hasReleaseKey = !releaseKeystore.isNullOrBlank() && !releaseKeystorePassword.isNullOrBlank() &&
    !releaseKeyAlias.isNullOrBlank() && !releaseKeyPassword.isNullOrBlank() &&
    releaseKeystoreFile != null && releaseKeystoreFile.exists()

// #409 / #408's sibling: a **signed** release must not ship without Firebase config. Without the file the
// Google Services plugin above is not applied, so there are no `google_app_id`/`gcm_defaultSenderId`
// resources, `getToken()` returns nothing and no push token can register - silently, with no error. The
// debug artefacts are allowed to build config-less on purpose (#317); only the upload path is refused.
// A half-configured release is a mistake, not a choice: name what is missing rather than silently
// falling back to the debug key, which is how the keystore-path bug above stayed invisible.
val anyReleaseEnv = listOf(releaseKeystore, releaseKeystorePassword, releaseKeyAlias, releaseKeyPassword)
    .any { !it.isNullOrBlank() }
if (anyReleaseEnv && !hasReleaseKey) {
    val missing = mutableListOf<String>()
    if (releaseKeystore.isNullOrBlank()) missing.add("OSRA_UPLOAD_KEYSTORE")
    if (releaseKeystorePassword.isNullOrBlank()) missing.add("OSRA_UPLOAD_KEYSTORE_PASSWORD")
    if (releaseKeyAlias.isNullOrBlank()) missing.add("OSRA_UPLOAD_KEY_ALIAS")
    if (releaseKeyPassword.isNullOrBlank()) missing.add("OSRA_UPLOAD_KEY_PASSWORD")
    // All four set but the flag is still false: the file is the problem, so name the resolved path.
    if (missing.isEmpty()) missing.add("a keystore file at ${releaseKeystoreFile?.absolutePath ?: "?"} (not found)")
    throw GradleException("release signing is half configured; missing or unusable: ${missing.joinToString()}")
}

// #409: a **signed** release must not ship without Firebase config — no `google_app_id`, so `getToken()`
// returns nothing and no token can register, silently. Debug variants stay config-less by design (#317).
if (hasReleaseKey && !file("google-services.json").exists()) {
    throw GradleException(
        "google-services.json is missing for a signed release build (a release keystore is configured). " +
            "Add app/google-services.json (the child agent's layout), or build a debug variant.",
    )
}

android {
    namespace = "com.familyshield.agent"
    // Plan 1.8: targetSdk 35 (Play's 2025 requirement). compileSdk 35 is one above what AGP 8.4 lists as
    // tested; it warns and builds.
    compileSdk = 35
    buildToolsVersion = "35.0.0"
    defaultConfig {
        applicationId = "com.familyshield.agent"
        minSdk = 26
        targetSdk = 35
        versionCode = 2
        versionName = "0.2.0"
    }
    signingConfigs {
        create("release") {
            if (hasReleaseKey) {
                storeFile = releaseKeystoreFile
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildFeatures {
        compose = true
        // ADR-0016 §4: the onboarding row that names notification capture must exist only in Full.
        buildConfig = true
    }
    composeOptions { kotlinCompilerExtensionVersion = "1.5.14" }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildTypes {
        release {
            // Plan 1.8: shrunk and obfuscated; the keep rules in proguard-rules.pro cover Moshi's
            // reflective DTOs, Retrofit, Room, Hilt and the OS-instantiated components.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("OSRA: no release keystore in the environment (OSRA_UPLOAD_KEYSTORE / _PASSWORD / OSRA_UPLOAD_KEY_ALIAS / OSRA_UPLOAD_KEY_PASSWORD) — release APK is debug-signed")
                signingConfigs.getByName("debug")
            }
        }
        debug {
            // The debug build keeps cleartext (LAN / 10.0.2.2 dev servers) via src/debug/res/xml/network_security_config.xml.
        }
    }
    /**
     * ADR-0016: two distribution builds. `play` declares neither the notification listener nor
     * BIND_NOTIFICATION_LISTENER_SERVICE, so the store artefact cannot read notifications at all;
     * `full` adds `src/full/AndroidManifest.xml` and the listener service. Variant names are spelled
     * out at every call site (CI, the signing script, the docs) — no aliases, so a missing variant is
     * a build error rather than a silently different artefact.
     */
    flavorDimensions += "distribution"
    productFlavors {
        create("play") {
            dimension = "distribution"
            // No NotificationListenerService and no BIND_NOTIFICATION_LISTENER_SERVICE in this artefact,
            // so onboarding must not ask for a permission the build cannot use (ADR-0016 §4).
            buildConfigField("boolean", "CAPTURE_NOTIFICATIONS", "false")
            // ADR-0021: no READ_CALL_LOG / READ_SMS in this artefact, so the observer must not register.
            buildConfigField("boolean", "CAPTURE_CALL_SMS", "false")
        }
        create("full") {
            dimension = "distribution"
            buildConfigField("boolean", "CAPTURE_NOTIFICATIONS", "true")
            buildConfigField("boolean", "CAPTURE_CALL_SMS", "true")
        }
    }
}

kapt {
    // Required by Hilt: rewrites error types (e.g. @error.NonExistentClass stubs) during kapt.
    correctErrorTypes = true
}

/**
 * ADR-0021's merged-manifest gate (`PlayMergedManifestTest`, `FullMergedManifestTest`) reads the
 * manifest AGP produced after merging, `app/build/intermediates/merged_manifests/<flavor><BuildType>/…`.
 * `process<Flavor><BuildType>Manifest` is what writes it, and the unit-test task does not otherwise
 * depend on it — so without the wiring below the gate would skip on a clean build (which is how the hole
 * it closes stayed invisible). Both flavours and both build types are merged for either test task because
 * each gate class reads its own artefacts, and a missing artefact is then a real failure instead of a
 * routine skip. Issue #170 uses the release half: `android:testOnly` must be present in the debug merge
 * and absent from the release merge, so the release manifest has to be built by the same task that runs
 * the assertion.
 */
tasks.withType<org.gradle.api.tasks.testing.Test>().configureEach {
    val variant = Regex("""^test(Play|Full)(Debug)UnitTest$""").matchEntire(name) ?: return@configureEach
    // MergedManifestLocator documents `-Dosra.mergedManifest.<variant>=<path>` for pointing the gate at a
    // manifest explicitly, but Gradle does not pass arbitrary CLI `-D` properties to the test worker.
    // Forward the `osra.*` ones so that documented override (and the doctored-input check) works.
    System.getProperties().forEach { key, value ->
        val property = key.toString()
        if (property.startsWith("osra.")) systemProperty(property, value.toString())
    }
    for (flavor in listOf("Play", "Full")) {
        for (buildType in listOf(variant.groupValues[2], "Release")) {
            dependsOn("process$flavor${buildType}Manifest")
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.0")
    implementation("androidx.lifecycle:lifecycle-service:2.8.0")
    implementation("com.google.dagger:hilt-android:2.51.1")
    kapt("com.google.dagger:hilt-compiler:2.51.1")
    implementation("com.squareup.retrofit2:retrofit:2.11.0")
    implementation("com.squareup.retrofit2:converter-moshi:2.11.0")
    implementation("com.squareup.moshi:moshi-kotlin:1.15.1")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")
    implementation("com.google.android.gms:play-services-location:21.2.0")
    implementation("com.google.firebase:firebase-messaging-ktx:24.0.0")
    implementation("androidx.work:work-runtime-ktx:2.9.0")
    implementation("androidx.datastore:datastore-preferences:1.1.1")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    // Roadmap 3.2: QR pairing. CameraX is Apache-2.0. The ML Kit barcode model is bundled (its
    // licence is Google's ML Kit terms, not Apache-2.0) so the first scan works offline — the
    // five-minute first-run test must not wait for a model download. Size is measured in the PR.
    implementation("androidx.camera:camera-core:1.3.4")
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.camera:camera-view:1.3.4")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")

    // Room (ksp compiler)
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")

    // Compose (BOM + activity-compose + material3) for BlockActivity/LockActivity
    implementation(platform("androidx.compose:compose-bom:2024.05.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.activity:activity-compose:1.9.0")

    testImplementation("junit:junit:4.13.2")
}
