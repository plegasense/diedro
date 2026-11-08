import java.util.Properties

plugins { id("com.android.application") }

val local = Properties().apply { file("../local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) } }
val occtDir = local.getProperty("occt.dir") ?: error("Falta occt.dir en local.properties (carpeta install de OpenCASCADE arm64)")

android {
    namespace = "app.diedro.planos"
    compileSdk = 36
    defaultConfig {
        applicationId = "app.diedro.planos"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild { cmake { arguments += listOf("-DOCCT_DIR=$occtDir/lib/cmake/opencascade", "-DANDROID_STL=c++_shared"); cppFlags += "-std=c++17" } }
    }
    externalNativeBuild { cmake { path = file("../../core/CMakeLists.txt") } }
    val ks = Properties().apply { file(System.getProperty("user.home") + "/.diedro-keys/keystore.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) } }
    signingConfigs { if (ks.isNotEmpty()) create("release") { storeFile = file(ks.getProperty("storeFile")); storePassword = ks.getProperty("storePassword"); keyAlias = ks.getProperty("keyAlias"); keyPassword = ks.getProperty("keyPassword") } }
    buildTypes { release { isMinifyEnabled = true; isShrinkResources = true; proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro"); if (ks.isNotEmpty()) signingConfig = signingConfigs.getByName("release") } }
    packaging { jniLibs { useLegacyPackaging = false } }
}

dependencies { releaseImplementation("app.diedro.visor:flutter_release:1.0") }
