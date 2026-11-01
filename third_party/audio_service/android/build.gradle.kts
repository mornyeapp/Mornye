group = "com.ryanheise.audioservice"
version = "1.0-SNAPSHOT"
// androidx.media 1.8 deprecates its whole compat media-session API in favor of
// Media3. This plugin is built on that API, so per-use deprecation listings
// only bury real warnings; javac still prints a one-line deprecation note.
val args = listOf("-Xlint:unchecked")

// The host app supplies the Android Gradle Plugin version for every module.
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

tasks.withType<JavaCompile>().configureEach {
    options.compilerArgs.addAll(args)
}

// Uncomment when moving to Kotlin
// val agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
// if (agpMajor < 9) {
//    apply(plugin = "org.jetbrains.kotlin.android")
// }

android {
    namespace = "com.ryanheise.audioservice"
    compileSdk = 37

    defaultConfig {
        minSdk = 19
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Uncomment when moving to Kotlin
    // sourceSets {
    //     getByName("main") {
    //         java.srcDirs("src/main/kotlin")
    //     }
    //     getByName("test") {
    //         java.srcDirs("src/test/kotlin")
    //     }
    // }

    lint {
        disable += listOf("InvalidPackage")
    }
}

dependencies {
    implementation("androidx.media:media:1.8.0")
    implementation("androidx.core:core:1.19.1")
    testImplementation("junit:junit:4.13.2")
}
