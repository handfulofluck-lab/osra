package com.familyshield.agent.data.db

import androidx.room.Database
import androidx.room.RoomDatabase

/** Room database for unsent location pings, usage events, comms events and agent watermarks. */
@Database(
    entities = [PendingPingEntity::class, UsageEventEntity::class, AgentStateEntity::class, CommsEventEntity::class],
    version = 2,
    exportSchema = false,
)
abstract class FamilyShieldDatabase : RoomDatabase() {

    /** DAO for unsent location pings. */
    abstract fun pendingPingDao(): PendingPingDao

    /** DAO for raw usage events. */
    abstract fun usageEventDao(): UsageEventDao

    /** DAO for agent key/value state. */
    abstract fun agentStateDao(): AgentStateDao

    /** DAO for unsent call/SMS events (Feature #6). */
    abstract fun commsEventDao(): CommsEventDao
}
