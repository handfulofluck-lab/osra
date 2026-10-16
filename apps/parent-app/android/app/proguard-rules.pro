# Flutter + plugins keep rules (google_maps_flutter, fl_chart are reflection-free; Flutter adds its own).
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**
