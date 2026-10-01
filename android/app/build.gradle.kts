import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key, kept out of git (see README → Release).
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use(::load)
}

// `flutter build apk --android-project-arg=aniviewBeta=true` makes a second, installable app.
val betaBuild = project.findProperty("aniviewBeta") == "true"

android {
    namespace = "com.kidfury.aniview"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = if (betaBuild) "com.kidfury.aniview.beta" else "com.kidfury.aniview"
        manifestPlaceholders["appLabel"] = if (betaBuild) "AniView Beta" else "AniView"
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
    }

    signingConfigs {
        create("release") {
            keyAlias = keyProperties.getProperty("keyAlias")
            keyPassword = keyProperties.getProperty("keyPassword")
            storeFile = keyProperties.getProperty("storeFile")?.let(::file)
            storePassword = keyProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            // Without android/key.properties, release builds fall back to the debug key so `flutter run --release` works.
            signingConfig = signingConfigs.getByName(if (keyProperties.isEmpty) "debug" else "release")
        }
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
    implementation("androidx.documentfile:documentfile:1.1.0")
    // Playback, as CloudStream does it: ExoPlayer with HLS.
    val media3 = "1.8.0"
    implementation("androidx.media3:media3-exoplayer:$media3")
    implementation("androidx.media3:media3-exoplayer-hls:$media3")
    // What Aniyomi extensions are built against and expect the app to provide, at Aniyomi's versions.
    implementation("com.squareup.okhttp3:okhttp:5.4.0")
    implementation("org.jsoup:jsoup:1.22.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json-okio:1.9.0")
    implementation("com.github.mihonapp:injekt:91edab2317")
    implementation("androidx.preference:preference-ktx:1.2.1")
    implementation("app.cash.quickjs:quickjs-android:0.9.2")
}
