import org.gradle.process.ExecOperations

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "app.yuyue"
    compileSdk = 37
    buildToolsVersion = "36.1.0"

    defaultConfig {
        applicationId = "app.yuyue"
        // Android 8: TECH.md §十二.
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // The reader bundle (`cd reader && pnpm build`) is served to the WebView as /app/….
    sourceSets["main"].assets.directories.add("../../reader/dist")

    packaging { jniLibs { useLegacyPackaging = false } }
}

kotlin { jvmToolchain(21) }

/** English for the interface, from the catalog the Apple app uses (scripts/l10n-android.py). */
abstract class L10nTask : DefaultTask() {
    @get:InputFile abstract val catalog: RegularFileProperty
    @get:InputFile abstract val extra: RegularFileProperty
    @get:InputFile abstract val script: RegularFileProperty
    @get:OutputDirectory abstract val outputDir: DirectoryProperty
    @get:javax.inject.Inject abstract val exec: ExecOperations

    @TaskAction
    fun run() {
        exec.exec { commandLine("python3", script.get().asFile.path, outputDir.get().file("l10n/en.json").asFile.path) }
    }
}

val l10n = tasks.register<L10nTask>("l10n") {
    catalog.set(file("../../apple/Yuyue/Localizable.xcstrings"))
    extra.set(file("src/main/l10n/extra-en.json"))
    script.set(file("../../scripts/l10n-android.py"))
    outputDir.set(layout.buildDirectory.dir("generated/l10n"))
}

androidComponents {
    onVariants { variant -> variant.sources.assets?.addGeneratedSourceDirectory(l10n, L10nTask::outputDir) }
}

dependencies {
    val bom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(bom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.navigation:navigation-compose:2.9.5")
    implementation("androidx.webkit:webkit:1.14.0")
    implementation("androidx.media3:media3-session:1.8.0")
    implementation("androidx.media3:media3-exoplayer:1.8.0")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.security:security-crypto:1.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    // WebDAV needs PROPFIND and MKCOL, which the platform client refuses.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // UniFFI's Kotlin bindings call the core through JNA.
    implementation("net.java.dev.jna:jna:5.18.1@aar")
}
