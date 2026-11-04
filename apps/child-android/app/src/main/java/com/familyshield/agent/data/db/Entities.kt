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
    /**
     * The call log's number, or — for a WhatsApp call (roadmap 4.5) — the contact name WhatsApp gave us.
     * WhatsApp never shows a number, so the name is the only identity there is; the parent app renders this
     * field as the row's label.
     *
     * **When [source] is `whatsapp` this is a name, never a number, and nothing may treat it as one:** no
     * normalising, dialling or allowlist-matching, because `"Mama 2"` normalises to `"2"` and would either be
     * dialled or matched against a stranger's digits (Claude, #532 review). `CommsLogger.recordCall` never
     * reaches `maybeAlertUnknownContact`, and that must stay true.
     */
    val number: String,
    /** incoming | outgoing | missed | unknown | other. */
    val direction: String,
    /**
     * Seconds, or **null when the length is not known** — a WhatsApp call that was never answered has none,
     * and `0` would read as a call that connected and ended instantly. Nullable since room version 4.
     */
    val durationSec: Int? = null,
    /** SMS body preview (capped at 120 chars), null for calls. */
    val bodyPreview: String? = null,
    val timestamp: Long,
    /** `whatsapp` for a call read from its notifications; null for a row the call log wrote (roadmap 4.5). */
    val source: String? = null,
    /** True when [durationSec] was measured from notifications rather than timed, so the screen says "about". */
    val durationApprox: Boolean = false,
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
