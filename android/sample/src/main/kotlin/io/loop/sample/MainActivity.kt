package io.loop.sample

import android.app.Activity
import android.os.Bundle
import android.widget.Button
import io.loop.analytics.LoopAnalytics

class MainActivity : Activity() {
    private var index = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val button = Button(this)
        button.text = "Track Item Viewed"
        button.setOnClickListener {
            index += 1
            LoopAnalytics.track("Item Viewed", mapOf("Index" to index))
        }
        setContentView(button)
    }
}
