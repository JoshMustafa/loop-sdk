import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Minimal host app for trying the SDK by hand. Not published.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "io.loop.sample"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.loop.sample"
        minSdk = 21
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_1_8)
    }
}

dependencies {
    implementation(project(":loop-analytics"))
}
