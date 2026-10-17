package com.familyshield.agent.data.db

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/** Room database for unsent location pings, usage events, comms events, pending scans and agent watermarks. */
@Database(
    entities = [PendingPingEntity::class, UsageEventEntity::class, AgentStateEntity::class, CommsEventEntity::class, PendingScanEntity::class],
    version = 3,
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

    /** DAO for the durable scan queue (plan 2.6). */
    abstract fun pendingScanDao(): PendingScanDao

    companion object {
        /** Plan 2.6: adds `pending_scans`; nothing else changes, so the existing rows are kept. */
        val MIGRATION_2_3: Migration = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `pending_scans` (`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
                        "`app` TEXT NOT NULL, `contact` TEXT, `text` TEXT NOT NULL, `source` TEXT NOT NULL, " +
                        "`createdAt` INTEGER NOT NULL, `attempts` INTEGER NOT NULL)",
                )
            }
        }
    }
}
