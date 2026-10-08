import java.net.URI
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("kotlin-android")
    // Push notifications (FCM) only; no other Firebase product is used.
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.child_assist"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.child_assist"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // On-device checks of the wake word (src/androidTest): real model, native library, microphone.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    // The "Hey Child" model is read straight from the APK; storing it uncompressed avoids an
    // extra copy in memory when it loads.
    androidResources {
        noCompress += "onnx"
    }

    packaging {
        jniLibs {
            // sherpa-onnx's JNI library needs only libonnxruntime.so; its C/C++ API libraries are
            // for other languages. Flutter does not ship 32-bit x86, so neither does the engine.
            excludes += listOf("**/libsherpa-onnx-c-api.so", "**/libsherpa-onnx-cxx-api.so", "lib/x86/**")
        }
    }
}

flutter {
    source = "../.."
}

// Wake word ("Hey Child"): sherpa-onnx (Apache 2.0, https://github.com/k2-fsa/sherpa-onnx), an
// offline keyword spotter. It is not on Maven Central, so the official release AAR is downloaded
// once into libs/ (git-ignored) and checked against a pinned SHA-256 before it is used.
val sherpaOnnxVersion = "1.13.8"
val sherpaOnnxSha256 = "633c24321e06b1fe79feafa03ea16cbc0f8a286641e2da3559bac91bdb13bd96"
val sherpaOnnxAar = file("libs/sherpa-onnx-$sherpaOnnxVersion.aar")

fun sha256(file: File): String =
    MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }

if (!sherpaOnnxAar.exists() || sha256(sherpaOnnxAar) != sherpaOnnxSha256) {
    val url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$sherpaOnnxVersion/sherpa-onnx-$sherpaOnnxVersion.aar"
    logger.lifecycle("Downloading sherpa-onnx $sherpaOnnxVersion for the wake word")
    sherpaOnnxAar.parentFile.mkdirs()
    val partial = File(sherpaOnnxAar.path + ".part")
    URI(url).toURL().openStream().use { input -> partial.outputStream().use { input.copyTo(it) } }
    val actual = sha256(partial)
    if (actual != sherpaOnnxSha256) {
        partial.delete()
        throw GradleException("sherpa-onnx AAR checksum mismatch: expected $sherpaOnnxSha256, got $actual")
    }
    partial.renameTo(sherpaOnnxAar)
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Extracts the text of a PDF the user asks the assistant about, on the phone (Apache 2.0).
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    // The wake word's foreground-service notification.
    implementation("androidx.core:core-ktx:1.16.0")
    implementation(files(sherpaOnnxAar))
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
}
