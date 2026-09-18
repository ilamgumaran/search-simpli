plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "family.searchsimpli.search_simpli_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "family.searchsimpli.search_simpli_example"
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

        // ../../native/android-arm64/libsearch_simpli.so (docs/tasks/S1-T2.md
        // criterion 1) is the only prebuilt Android library this package
        // ships (ADR 0002's Android target is arm64 only); restrict this
        // example app to arm64-v8a so a plain `flutter build apk` never
        // tries to resolve a native library for another ABI.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    // src/main/jniLibs/arm64-v8a/libsearch_simpli.so is a copy of
    // ../../native/android-arm64/libsearch_simpli.so, kept in sync by
    // ../../tool/build_native.sh — this is the standard Android convention
    // `lib/src/library_loader.dart` relies on
    // (`DynamicLibrary.open('libsearch_simpli.so')`).

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
