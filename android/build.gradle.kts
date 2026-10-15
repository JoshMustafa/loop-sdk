plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
}

// Maven coordinates for the library modules. JitPack builds with GROUP set to
// `com.github.<user>` and ARTIFACT to the repo name, and serves a multi-module
// repo as `com.github.<user>.<repo>:<module>`, so the published POMs (and the
// loop-analytics -> loop-core dependency in them) must already use that group.
// Local builds publish as `io.loop:<module>:2.0.0`.
val publishGroup: String = run {
    val group = System.getenv("GROUP")?.takeIf { it.isNotBlank() }
    val artifact = System.getenv("ARTIFACT")?.takeIf { it.isNotBlank() }
    when {
        group != null && artifact != null -> "$group.$artifact"
        group != null -> group
        else -> "io.loop"
    }
}
val publishVersion: String = System.getenv("VERSION")?.takeIf { it.isNotBlank() } ?: "2.0.0"

extra["loopPublishGroup"] = publishGroup
extra["loopPublishVersion"] = publishVersion
