package io.loop.core

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import org.json.JSONObject
import java.util.Locale

/**
 * Device and app facts sent as the batch-level `context` object. Captured
 * once; `locale` is the only field expected to change while the app runs.
 */
@InternalLoopApi
public data class LoopContext(
    /** `Android`. */
    val platform: String,
    /** `android`. */
    val osName: String? = null,
    val osVersion: String? = null,
    /** Version name only, e.g. `5.57.0`. */
    val appVersion: String? = null,
    /** Version code as a string, e.g. `1234`. */
    val appBuild: String? = null,
    val deviceModel: String? = null,
    val deviceManufacturer: String? = null,
    val deviceBrand: String? = null,
    val isTablet: Boolean? = null,
    /** BCP 47 style, e.g. `en-GB`. */
    val locale: String? = null,
) {
    /**
     * The wire `context` object. Null fields are left out, except
     * `purchaserId`, which is always present ([JSONObject.NULL] when null).
     */
    public fun json(purchaserId: String?, sdk: Pair<String, String>): JSONObject {
        val out = JSONObject()
        out.put("platform", platform)
        out.putOpt("osName", osName)
        out.putOpt("osVersion", osVersion)
        out.putOpt("appVersion", appVersion)
        out.putOpt("appBuild", appBuild)
        out.putOpt("deviceModel", deviceModel)
        out.putOpt("deviceManufacturer", deviceManufacturer)
        out.putOpt("deviceBrand", deviceBrand)
        out.putOpt("isTablet", isTablet)
        out.putOpt("locale", locale)
        out.put("purchaserId", purchaserId ?: JSONObject.NULL)
        out.put("sdk", JSONObject().put("name", sdk.first).put("version", sdk.second))
        return out
    }

    public companion object {
        /** Snapshot of the running device and the app that owns [context]. */
        @JvmStatic
        public fun capture(context: Context): LoopContext {
            val packageInfo = packageInfo(context)
            val configuration = context.resources.configuration
            val smallestWidth = configuration.smallestScreenWidthDp
            return LoopContext(
                platform = "Android",
                osName = "android",
                osVersion = nonEmpty(Build.VERSION.RELEASE),
                appVersion = nonEmpty(packageInfo?.versionName),
                appBuild = packageInfo?.let { versionCode(it).toString() },
                deviceModel = nonEmpty(Build.MODEL),
                deviceManufacturer = nonEmpty(Build.MANUFACTURER),
                deviceBrand = nonEmpty(Build.BRAND),
                isTablet = if (smallestWidth == Configuration.SMALLEST_SCREEN_WIDTH_DP_UNDEFINED) {
                    null
                } else {
                    smallestWidth >= 600
                },
                locale = localeTag(primaryLocale(configuration)),
            )
        }

        /**
         * A BCP 47 tag holding only language, optional script and optional
         * region, e.g. `en-GB` or `zh-Hant-TW`. Extensions (`-u-…`), variants
         * and private-use parts are dropped. Null when the locale has no language.
         */
        @JvmStatic
        public fun localeTag(locale: Locale): String? {
            // toLanguageTag() also maps legacy codes (iw → he, in → id, ji → yi).
            val subtags = locale.toLanguageTag().split('-')
            val language = subtags.firstOrNull() ?: return null
            if (language.length !in 2..8 || !language.all { it.isAsciiLetter() } || language == "und") return null

            val tag = mutableListOf(language.lowercase(Locale.ROOT))
            var i = 1
            val script = subtags.getOrNull(i)
            if (script != null && script.length == 4 && script.all { it.isAsciiLetter() }) {
                tag += script.substring(0, 1).uppercase(Locale.ROOT) + script.substring(1).lowercase(Locale.ROOT)
                i += 1
            }
            val region = subtags.getOrNull(i)
            if (region != null &&
                ((region.length == 2 && region.all { it.isAsciiLetter() }) ||
                    (region.length == 3 && region.all { it.isAsciiDigit() }))
            ) {
                tag += region.uppercase(Locale.ROOT)
            }
            return tag.joinToString("-")
        }

        private fun primaryLocale(configuration: Configuration): Locale =
            if (Build.VERSION.SDK_INT >= 24) {
                configuration.locales.takeIf { !it.isEmpty }?.get(0) ?: Locale.getDefault()
            } else {
                @Suppress("DEPRECATION")
                configuration.locale ?: Locale.getDefault()
            }

        private fun packageInfo(context: Context): PackageInfo? = try {
            if (Build.VERSION.SDK_INT >= 33) {
                context.packageManager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(context.packageName, 0)
            }
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }

        private fun versionCode(info: PackageInfo): Long =
            if (Build.VERSION.SDK_INT >= 28) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }

        private fun nonEmpty(s: String?): String? = s?.takeIf { it.isNotEmpty() }

        private fun Char.isAsciiLetter(): Boolean = this in 'a'..'z' || this in 'A'..'Z'

        private fun Char.isAsciiDigit(): Boolean = this in '0'..'9'
    }
}
