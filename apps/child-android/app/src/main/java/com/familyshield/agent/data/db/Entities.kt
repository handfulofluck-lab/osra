package com.familyshield.agent.data.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/** A location sample that has not yet been uploaded to the backend. */
@Entity(tableName = "pending_pings")
data class PendingPingEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val lat: Double,
    val lng: Double,
    val accuracyM: Float,
    val timestamp: Long,
)

/** A foreground-app transition observed by the accessibility service. */
@Entity(tableName = "usage_events")
data class UsageEventEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val packageId: String,
    val timestamp: Long,
)

/** Single-row key/value long store for aggregation watermarks. */
@Entity(tableName = "agent_state")
data class AgentStateEntity(
    @PrimaryKey val key: String,
    val valueLong: Long,
)

/** A call or SMS event that has not yet been uploaded (Feature #6). */
@Entity(tableName = "comms_events")
data class CommsEventEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** call | sms. */
    val type: String,
    val number: String,
    /** incoming | outgoing | missed | other. */
    val direction: String,
    val durationSec: Int = 0,
    /** SMS body preview (capped at 120 chars), null for calls. */
    val bodyPreview: String? = null,
    val timestamp: Long,
)

/**
 * Plan 2.6: a redacted social capture waiting to be scanned by the server. Rows survive a process
 * kill, a reboot and an offline stretch; [attempts] counts failed POSTs so a poison row is dropped
 * instead of blocking the queue (see [com.familyshield.agent.social.ScanQueuePolicy]).
 */
@Entity(tableName = "pending_scans")
data class PendingScanEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val app: String,
    val contact: String?,
    val text: String,
    /** screen | notification — where the text came from. */
    val source: String,
    val createdAt: Long,
    val attempts: Int = 0,
)
