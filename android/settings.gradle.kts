pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories {
    google(); mavenCentral()
    maven { url = uri("../visor/app/build/host/outputs/repo") }
    maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
} }
rootProject.name = "Diedro"
include(":app")
