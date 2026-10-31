import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Direct Flutter builds also need the revision displayed in About.
val buildDartDefines = providers.exec {
    workingDir(rootProject.projectDir.parentFile)
    commandLine(
        "bash",
        "scripts/flutter_git_commit.sh",
        project.findProperty("dart-defines")?.toString().orEmpty(),
    )
}.standardOutput.asText.get().trim()
project.extensions.extraProperties["dart-defines"] = buildDartDefines

// Flutter reads this when configuring variant tasks, after this build script.
// Keep release AOT debug data outside libapp.so; explicit paths and size analysis take precedence.
if (!project.hasProperty("split-debug-info") && !project.hasProperty("code-size-directory")) {
    project.extensions.extraProperties["split-debug-info"] =
        rootProject.file("../build/symbols/android").absolutePath
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val rustBackendDir = rootProject.file("../rust_backend")
val rustAndroidAbis = providers.environmentVariable("MORNYE_RUST_ANDROID_ABIS")
    .orElse("arm64-v8a,armeabi-v7a")
    .get()
    .split(",")
val supportedRustAndroidAbis = setOf("arm64-v8a", "armeabi-v7a")
val discordSdkEnabled = providers.environmentVariable("MORNYE_DISCORD_SDK").orElse("1").get() != "0"
require(rustAndroidAbis.size == rustAndroidAbis.toSet().size) {
    "MORNYE_RUST_ANDROID_ABIS must not contain duplicate ABIs"
}
require(rustAndroidAbis.all { it in supportedRustAndroidAbis }) {
    "MORNYE_RUST_ANDROID_ABIS must contain only arm64-v8a and/or armeabi-v7a"
}

android {
    namespace = "com.zarz.mornye"
    compileSdk = 37
    ndkVersion = "30.0.16248370"

    buildFeatures {
        buildConfig = true
    }
    packaging {
        if (discordSdkEnabled) jniLibs.pickFirsts += "**/libdiscord_partner_sdk.so"
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "4.1.2"
        }
    }

    sourceSets.getByName("main") {
        java.srcDir("src/rust/kotlin")
        java.srcDir(rustBackendDir.resolve("target/bindings/kotlin"))
        jniLibs.srcDir(rustBackendDir.resolve("target/android/jniLibs"))
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_25
        targetCompatibility = JavaVersion.VERSION_25
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_25)
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
                // V4 lives in a separate .apk.idsig file used for
                // `adb install --incremental`; the APK itself is unchanged.
                enableV4Signing = true
            }
        }
    }

    defaultConfig {
        applicationId = "com.zarz.mornye"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        minSdk = flutter.minSdkVersion
        targetSdk = 37
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_STL=c++_static",
                    // Oboe's minimum predates the policies removed in CMake 4.
                    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
                )
            }
        }

        ndk {
            abiFilters.clear()
            abiFilters += rustAndroidAbis
        }
    }

    buildTypes {
        getByName("debug") {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            ndk {
                debugSymbolLevel = "FULL"
            }
        }

        getByName("profile") {
            ndk {
                debugSymbolLevel = "FULL"
            }
        }

        release {
            // For local builds: use release signing if key.properties exists
            // For CI builds: APK is signed by GitHub Action after build
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            ndk {
                debugSymbolLevel = "FULL"
            }
        }
    }

    splits {
        abi {
            isEnable = true
            reset()
            include(*rustAndroidAbis.toTypedArray())
            isUniversalApk = true // Also generate universal APK
        }
    }
}

val buildRustBackend = tasks.register<Exec>("buildRustBackend") {
    workingDir(rootProject.projectDir.parentFile)
    commandLine("bash", "scripts/build_rust_backend.sh", "android")
    environment("MORNYE_RUST_ANDROID_ABIS", rustAndroidAbis.joinToString(","))
    environment(
        "ANDROID_NDK_HOME",
        System.getenv("ANDROID_NDK_HOME")
            ?: android.sdkDirectory.resolve("ndk/30.0.16248370").absolutePath,
    )
    inputs.files(fileTree(rustBackendDir) {
        include("**/*.rs", "**/*.toml", "**/*.lock", "**/*.js", "**/*.tsv", "**/*.pem")
        exclude("target/**", "smoke/**")
    })
    inputs.property("MORNYE_RUST_ANDROID_ABIS", rustAndroidAbis.joinToString(","))
    inputs.file(rootProject.file("../scripts/build_rust_backend.sh"))
    outputs.dir(rustBackendDir.resolve("target/bindings/kotlin"))
    outputs.dir(rustBackendDir.resolve("target/android/jniLibs"))
}
tasks.named("preBuild").configure { dependsOn(buildRustBackend) }

// Filter Android's copy only; keep shared bundles and mobile glass shaders intact.
tasks.withType<org.gradle.api.tasks.Copy>().configureEach {
    if (name.startsWith("copyFlutterAssets")) {
        exclude(
            "flutter_assets/packages/liquid_glass_easy/lib/assets/shaders/liquid_glass_desktop.frag",
            "flutter_assets/packages/liquid_glass_easy/lib/assets/shaders/metaball_glass_desktop.frag",
            "flutter_assets/packages/flutter_local_notifications_web/web/notifications_service_worker.js",
        )
    }
}

flutter {
    source = "../.."
}

dependencies {
    val discordSdk = file("../../third_party/mornye_discord/sdk/discord_partner_sdk.aar")
    if (discordSdkEnabled && discordSdk.exists()) {
        implementation(files(discordSdk))
    }
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("net.java.dev.jna:jna:5.19.1@aar")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.0")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.activity:activity-ktx:1.13.0")
    // NativeDownloadFinalizer imports FFmpegKit APIs directly. The Flutter
    // plugin owns the runtime AAR; compileOnly avoids packaging it twice here.
    compileOnly("com.antonkarpenko:ffmpeg-kit-audio:2.2.3")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20260814")
    // Keep Flutter integration_test's older runner aligned with native tests.
    debugImplementation("androidx.test:runner:1.7.0")
    debugImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.media:media:1.8.0")
}
