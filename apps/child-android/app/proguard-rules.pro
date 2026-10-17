# Plan 1.8 — keep rules for the minified release build.

# Moshi with KotlinJsonAdapterFactory reads DTO constructors and property names reflectively.
-keep class com.familyshield.agent.network.dto.** { *; }
-keepclassmembers class com.familyshield.agent.network.dto.** { *; }
-keep class kotlin.Metadata { *; }
-keep class kotlin.reflect.jvm.internal.** { *; }
-dontwarn kotlin.reflect.jvm.internal.**
-keepclassmembers class * { @com.squareup.moshi.FromJson <methods>; @com.squareup.moshi.ToJson <methods>; }
-keep @com.squareup.moshi.JsonQualifier interface *

# Retrofit: generic signatures on the service interface are what it parses.
-keepattributes Signature, InnerClasses, EnclosingMethod, Exceptions, *Annotation*
-keep,allowobfuscation,allowshrinking interface retrofit2.Call
-keep,allowobfuscation,allowshrinking class retrofit2.Response
-keep,allowobfuscation,allowshrinking class kotlin.coroutines.Continuation
-keep interface com.familyshield.agent.network.ApiService { *; }
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**

# Room entities / DAOs are generated against their names.
-keep class * extends androidx.room.RoomDatabase { *; }
-keep @androidx.room.Entity class * { *; }
-dontwarn androidx.room.paging.**

# Components the OS instantiates by name (manifest) and Hilt entry points.
-keep class com.familyshield.agent.FamilyShieldApp { *; }
-keep class * extends android.app.Service { *; }
-keep class * extends android.content.BroadcastReceiver { *; }
-keep class * extends android.app.Activity { *; }
-keep class * extends android.app.admin.DeviceAdminReceiver { *; }
-keep class * extends androidx.work.ListenableWorker { *; }
-keep @dagger.hilt.EntryPoint interface * { *; }

# Firebase / Play services ship their own consumer rules; silence the optional bits we don't use.
-dontwarn com.google.android.gms.**
-dontwarn com.google.firebase.**

# Crash lines stay readable.
-keepattributes SourceFile, LineNumberTable
-renamesourcefileattribute SourceFile
