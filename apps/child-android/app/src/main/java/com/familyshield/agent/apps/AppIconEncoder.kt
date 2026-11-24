package com.familyshield.agent.apps

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.util.Base64
import androidx.core.graphics.drawable.toBitmap
import java.io.ByteArrayOutputStream

/**
 * Karim, 23 Nov: "the Apps tab lacks any app icons". The installed-apps report carries each app's own
 * launcher icon so the parent sees the icon the child sees.
 *
 * What it is: the app's public launcher icon, rendered at [ICON_PX] px and compressed (WebP on
 * Android 11+, PNG before), base64 for the JSON report. It is not child content and carries no usage.
 *
 * Cost: icons are encoded only when the report is uploaded (the list changed, or the daily refresh),
 * never on an unchanged 15-minute tick. Each icon is capped at [MAX_ICON_BASE64] characters (the
 * server's cap) and the whole report at [MAX_TOTAL_ICON_BASE64]; an icon over either is left out and
 * that row draws a letter avatar in the parent.
 */
object AppIconEncoder {
    const val ICON_PX = 72
    const val MAX_ICON_BASE64 = 12_000
    const val MAX_TOTAL_ICON_BASE64 = 3_000_000
    private const val WEBP_QUALITY = 85

    /** Icons for [packageIds], in order, skipping any that fail to load or exceed the caps. */
    fun encodeAll(context: Context, packageIds: List<String>): Map<String, String> {
        val pm = context.packageManager
        val encoded = packageIds.map { pkg ->
            pkg to runCatching {
                val drawable = pm.getApplicationIcon(pkg)
                val bitmap = drawable.toBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888)
                compress(bitmap)
            }.getOrNull()
        }
        return withinBudget(encoded)
    }

    private fun compress(bitmap: Bitmap): String {
        val out = ByteArrayOutputStream()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            bitmap.compress(Bitmap.CompressFormat.WEBP_LOSSY, WEBP_QUALITY, out)
        } else {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    /**
     * Pure, so a JVM test can pin it: keep icons in list order while each is within [maxEach] and the
     * running total stays within [maxTotal]. A missing or oversized icon is skipped, not fatal.
     */
    fun withinBudget(
        icons: List<Pair<String, String?>>,
        maxEach: Int = MAX_ICON_BASE64,
        maxTotal: Int = MAX_TOTAL_ICON_BASE64,
    ): Map<String, String> {
        val kept = LinkedHashMap<String, String>()
        var total = 0
        for ((pkg, icon) in icons) {
            if (icon.isNullOrEmpty() || icon.length > maxEach) continue
            if (total + icon.length > maxTotal) continue
            kept[pkg] = icon
            total += icon.length
        }
        return kept
    }
}
