# Ignore missing Play Core classes (not used, but referenced by Flutter)
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# Ignore missing javax.xml.stream (not used on Android)
-dontwarn javax.xml.stream.**

# The FFmpeg plugin ships its JNI keep rules in its AAR.

# UniFFI/JNA resolves FFI methods and structure fields by their generated names.
# Preserve the generated Rust bindings used by JNA.
-keep class com.sun.jna.** { *; }
-keep class com.mornye.backend.** { *; }
# JNA's desktop AWT helpers are unavailable and unused on Android.
# https://github.com/java-native-access/jna/blob/master/www/FrequentlyAskedQuestions.md#jna-on-android
-dontwarn java.awt.Component
-dontwarn java.awt.GraphicsEnvironment
-dontwarn java.awt.HeadlessException
-dontwarn java.awt.Window

-keepclasseswithmembernames class * {
    native <methods>;
}

# Kuromoji loads its dictionary through its own class loader and resource names.
-keep class com.atilika.kuromoji.** { *; }
-keepnames class com.atilika.kuromoji.** { *; }
-dontwarn com.atilika.kuromoji.**

# Kotlin coroutines - expanded rules
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}
-keepclassmembernames class kotlinx.** {
    volatile <fields>;
}
-dontwarn kotlinx.coroutines.**

# Runtime annotations used by serializers and generated bindings.
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault
-dontwarn kotlin.**

# Android instantiates these components from the manifest. Preserve only their
# names and constructors; normal reachability can now shrink/optimize helpers,
# coroutine state machines, and unused members in the rest of the app package.
-keep,allowoptimization class com.zarz.mornye.MainActivity {
    public <init>();
}
-keep,allowoptimization class com.zarz.mornye.DownloadService {
    public <init>();
}
-keep,allowoptimization class com.zarz.mornye.DownloadQueueWidgetProvider {
    public <init>();
}

# Flutter's fragment builders instantiate this class through reflection.
-keep,allowoptimization class com.zarz.mornye.MainActivity$ImpellerAwareFlutterFragment {
    public <init>();
}

-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keepattributes Signature
-keepattributes Exceptions
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# Flutter invokes the generated registrant by name. Individual plugins are
# referenced by this class and retain their own consumer rules.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }
