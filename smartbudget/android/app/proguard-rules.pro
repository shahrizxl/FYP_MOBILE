# Protect Flutter Local Notifications
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class androidx.core.app.NotificationCompat** { *; }
-keep class io.flutter.plugins.urllauncher.** { *; }

# ✅ REQUIRED FOR GSON & SCHEDULED NOTIFICATIONS
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }
-keep class sun.misc.Unsafe { *; }