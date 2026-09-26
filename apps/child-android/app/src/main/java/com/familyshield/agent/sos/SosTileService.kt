package com.familyshield.agent.sos

import android.content.Intent
import android.service.quicksettings.TileService

/**
 * Feature #14 child SOS: quick-settings tile. Tapping the tile opens the full-screen SOS screen
 * (SosActivity) with its 5 s cancelable countdown (pocket-dial guard).
 */
class SosTileService : TileService() {

    @Suppress("DEPRECATION") // PendingIntent overload is API 34+; minSdk 26 must use the Intent one
    override fun onClick() {
        startActivityAndCollapse(
            Intent(this, SosActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
