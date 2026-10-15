import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    `maven-publish`
}

android {
    namespace = "io.loop.core"
    compileSdk = 35

    defaultConfig {
        minSdk = 21
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_1_8)
        // Built with Kotlin 2.2, but emits 1.9 metadata and uses only the 1.9
        // standard library API, so apps still on Kotlin 1.9 can consume it.
        // 1.9 is deprecated as a target; its deprecation warnings are silenced.
        @Suppress("DEPRECATION")
        languageVersion.set(KotlinVersion.KOTLIN_1_9)
        @Suppress("DEPRECATION")
        apiVersion.set(KotlinVersion.KOTLIN_1_9)
        freeCompilerArgs.add("-Xsuppress-version-warnings")
        optIn.add("io.loop.core.InternalLoopApi")
    }
}

dependencies {
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.org.json)
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = rootProject.extra["loopPublishGroup"] as String
            artifactId = "loop-core"
            version = rootProject.extra["loopPublishVersion"] as String
            afterEvaluate { from(components["release"]) }
        }
    }
}
