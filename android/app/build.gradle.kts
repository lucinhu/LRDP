plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val lrdpAbis = mapOf("android-arm" to "armeabi-v7a", "android-arm64" to "arm64-v8a", "android-x64" to "x86_64")
val lrdpTargets = providers.gradleProperty("target-platform").orElse("android-arm,android-arm64,android-x64").get().split(",")
val lrdpPreviewSigning = providers.environmentVariable("LRDP_ANDROID_PREVIEW_SIGNING").orNull == "1"
val lrdpStore = providers.environmentVariable("LRDP_ANDROID_KEYSTORE").orNull
val lrdpReleaseSigning = tasks.register("validateLrdpReleaseSigning") {
    doLast {
        check(lrdpPreviewSigning || lrdpStore != null) {
            "Release signing is required: set LRDP_ANDROID_KEYSTORE and the signing variables, " +
                "or explicitly set LRDP_ANDROID_PREVIEW_SIGNING=1 for a local development preview."
        }
    }
}

android {
    namespace = "dev.lrdp.lrdp"
    compileSdk = flutter.compileSdkVersion
    buildToolsVersion = "36.0.0"
    ndkVersion = providers.gradleProperty("lrdp.ndkVersion").orElse(flutter.ndkVersion).get()

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "dev.lrdp.lrdp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (providers.gradleProperty("split-per-abi").orNull != "true") {
            ndk {
                abiFilters.addAll(lrdpTargets.map { target ->
                    lrdpAbis[target.trim()] ?: error("Unsupported LRDP target platform: $target")
                })
            }
        }
    }

    if (lrdpStore != null) {
        check(!lrdpPreviewSigning) { "Choose release-key signing or preview signing, not both." }
        signingConfigs.create("lrdpRelease") {
            storeFile = file(lrdpStore)
            check(storeFile!!.isFile) { "LRDP_ANDROID_KEYSTORE does not point to a file." }
            fun secret(name: String): String = providers.environmentVariable(name).orNull
                ?: error("Missing signing variable: $name")
            keyAlias = secret("LRDP_ANDROID_KEY_ALIAS")
            storePassword = secret("LRDP_ANDROID_STORE_PASSWORD")
            keyPassword = secret("LRDP_ANDROID_KEY_PASSWORD")
        }
    }
    buildTypes {
        release {
            signingConfig = when {
                lrdpStore != null -> signingConfigs.getByName("lrdpRelease")
                lrdpPreviewSigning -> signingConfigs.getByName("debug")
                else -> null
            }
        }
    }

    packaging {
        // Keep the release APK small enough for app stores by compressing the
        // native libraries; Android extracts them once at install time.
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

tasks.matching { it.name in setOf("preReleaseBuild", "compileFlutterBuildRelease", "validateSigningRelease", "packageRelease") }
    .configureEach { dependsOn(lrdpReleaseSigning) }

flutter {
    source = "../.."
}
