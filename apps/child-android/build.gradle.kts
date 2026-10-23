plugins {
    id("com.android.application") version "8.4.1" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
    id("com.google.dagger.hilt.android") version "2.51.1" apply false
    id("com.google.devtools.ksp") version "1.9.24-1.0.20" apply false
    // Roadmap 1.5 (#319): FirebaseApp only initialises — and onNewToken only fires — when this plugin
    // has generated the resource values from app/google-services.json. Declared here so `:app` can
    // apply it conditionally; see app/build.gradle.kts for why it is not in that plugins block.
    id("com.google.gms.google-services") version "4.4.2" apply false
}
