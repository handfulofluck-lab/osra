package com.familyshield.agent.sos

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService

/**
 * Feature #14 child SOS: quick-settings tile. Tapping the tile opens the full-screen SOS screen
 * (SosActivity) with its 5 s cancelable countdown (pocket-dial guard).
 *
 * Android 14 (API 34) removed the `startActivityAndCollapse(Intent)` path: on those builds the
 * call throws/no-ops and the tap is swallowed, so the tile looked installed but never opened the
 * screen (found on a Galaxy Z Flip4 / Android 16 during TR-07). API 34+ must hand the system a
 * PendingIntent; older builds keep the Intent overload, which is all they have.
 */
class SosTileService : TileService() {

    override fun onClick() {
        val intent = Intent(this, SosActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pending = PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
