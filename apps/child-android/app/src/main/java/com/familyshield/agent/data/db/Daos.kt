package com.familyshield.agent.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

/** Data access for unsent location pings. */
@Dao
interface PendingPingDao {

    /** Inserts a batch of pending pings. */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(pings: List<PendingPingEntity>)

    /** Returns all pending pings, oldest first. */
    @Query("SELECT * FROM pending_pings ORDER BY timestamp ASC")
    suspend fun all(): List<PendingPingEntity>

    /** Deletes every pending ping (called after a successful upload). */
    @Query("DELETE FROM pending_pings")
    suspend fun clear()
}

/** Data access for raw foreground usage events. */
@Dao
interface UsageEventDao {

    /** Records one foreground-app event. */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(event: UsageEventEntity)

    /** Returns the oldest stored event timestamp, or null when empty. */
    @Query("SELECT MIN(timestamp) FROM usage_events")
    suspend fun oldestTimestamp(): Long?

    /** Returns all events at or after [timestamp], oldest first. */
    @Query("SELECT * FROM usage_events WHERE timestamp >= :timestamp ORDER BY timestamp ASC")
    suspend fun since(timestamp: Long): List<UsageEventEntity>

    /** Deletes events older than [timestamp] (already aggregated). */
    @Query("DELETE FROM usage_events WHERE timestamp < :timestamp")
    suspend fun deleteOlderThan(timestamp: Long)
}

/** Data access for the key/value agent state (e.g. telemetry watermark). */
@Dao
interface AgentStateDao {

    /** Returns the stored long for [key], or null. */
    @Query("SELECT valueLong FROM agent_state WHERE `key` = :key")
    suspend fun get(key: String): Long?

    /** Upserts [value] for [key]. */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun set(entity: AgentStateEntity)
}

/** Data access for unsent call/SMS events (Feature #6). */
@Dao
interface CommsEventDao {

    /** Inserts one comms event. */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(event: CommsEventEntity)

    /** Returns all events, oldest first. */
    @Query("SELECT * FROM comms_events ORDER BY timestamp ASC")
    suspend fun all(): List<CommsEventEntity>

    /** Deletes every event (called after a successful upload). */
    @Query("DELETE FROM comms_events")
    suspend fun clear()
}
