# Aniyomi extensions are loaded at runtime and call into the app, so R8 must keep what they're built against
# (Aniyomi's own keep rules, but without allowoptimization: R8 would mark methods nothing in the app overrides
# as final, and an extension overriding one then fails to load).
-keep class eu.kanade.** { *; }
-keep class androidx.preference.** { public protected *; }
-keep class android.content.** { *; }
-keep class uy.kohesive.injekt.** { public protected *; }
-keep class kotlin.** { public protected *; }
-keep class kotlinx.coroutines.** { public protected *; }
-keep class kotlinx.serialization.** { public protected *; }
-keep class okhttp3.** { public protected *; }
-keep class okio.** { public protected *; }
-keep class org.jsoup.** { public protected *; }
-keep class app.cash.quickjs.** { public protected *; }
-keepclasseswithmembers class okhttp3.MultipartBody$Builder { *; }
-keepattributes *Annotation*, InnerClasses, Signature
-dontwarn org.jspecify.annotations.**
-dontwarn javax.annotation.**
# Injekt reads the generic type off these anonymous classes, and R8 full mode strips signatures of unkept classes.
-keep,allowobfuscation class * extends uy.kohesive.injekt.api.FullTypeReference
-keep,allowobfuscation class * extends uy.kohesive.injekt.api.TypeReference
