import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    `maven-publish`
}

android {
    namespace = "io.loop.analytics"
    compileSdk = 35

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    testOptions {
        // android.util.Log and friends return defaults in plain JVM tests.
        unitTests.isReturnDefaultValues = true
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
    api(project(":loop-core"))
    // api: LoopAnalytics.flushAsync()/resetAsync() return a coroutines Job.
    api(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.lifecycle.process)

    testImplementation(libs.junit)
    testImplementation(libs.org.json)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = rootProject.extra["loopPublishGroup"] as String
            artifactId = "loop-analytics"
            version = rootProject.extra["loopPublishVersion"] as String
            afterEvaluate { from(components["release"]) }
        }
    }
}
