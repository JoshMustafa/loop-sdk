package io.loop.sample

import android.app.Application
import io.loop.core.Loop

class SampleApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Loop.configure(this, "loop_pk_REPLACE_ME")
    }
}
