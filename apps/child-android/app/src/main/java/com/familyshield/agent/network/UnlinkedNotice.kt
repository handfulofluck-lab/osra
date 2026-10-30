package com.familyshield.agent.network

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import com.familyshield.agent.R

/**
 * Issue #465: the one thing a phone whose family was deleted must say — that it is no longer linked, and
 * that the app can now be uninstalled.
 *
 * A notification rather than a full-screen activity on purpose: after an unlink nothing is enforcing, so
 * interrupting whatever the child is doing would be the agent grabbing attention it no longer earns. The
 * text is the action it enables, not an apology.
 */
object UnlinkedNotice {

    private const val CHANNEL = "osra_unlinked"
    private const val NOTIFICATION_ID = 7301

    fun show(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, context.getString(R.string.unlinked_channel), NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(context.getString(R.string.unlinked_title))
            .setContentText(context.getString(R.string.unlinked_body))
            .setStyle(NotificationCompat.BigTextStyle().bigText(context.getString(R.string.unlinked_body)))
            .setAutoCancel(true)
            .build()
        runCatching { manager.notify(NOTIFICATION_ID, notification) }
    }
}
