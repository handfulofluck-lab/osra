package com.familyshield.agent.data.db

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/** Room database for unsent location pings, usage events, comms events, pending scans and agent watermarks. */
@Database(
    entities = [PendingPingEntity::class, UsageEventEntity::class, AgentStateEntity::class, CommsEventEntity::class, PendingScanEntity::class],
    version = 4,
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

        /**
         * Roadmap 4.5: `comms_events` learns about a call we did not time.
         *
         * Two columns are added and `durationSec` becomes **nullable**, because a WhatsApp call that was never
         * answered has no length and `0` on the wire reads as a call that connected and ended instantly. SQLite
         * cannot relax `NOT NULL` in place, so the table is rebuilt around the same rows: a queued call or SMS
         * that has not been uploaded yet survives the upgrade, including its `id`.
         */
        val MIGRATION_3_4: Migration = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `comms_events` ADD COLUMN `source` TEXT")
                db.execSQL("ALTER TABLE `comms_events` ADD COLUMN `durationApprox` INTEGER NOT NULL DEFAULT 0")
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `comms_events_new` (" +
                        "`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `type` TEXT NOT NULL, " +
                        "`number` TEXT NOT NULL, `direction` TEXT NOT NULL, `durationSec` INTEGER, " +
                        "`bodyPreview` TEXT, `timestamp` INTEGER NOT NULL, `source` TEXT, " +
                        "`durationApprox` INTEGER NOT NULL)",
                )
                db.execSQL(
                    "INSERT INTO `comms_events_new` " +
                        "(`id`,`type`,`number`,`direction`,`durationSec`,`bodyPreview`,`timestamp`,`source`,`durationApprox`) " +
                        "SELECT `id`,`type`,`number`,`direction`,`durationSec`,`bodyPreview`,`timestamp`,`source`,`durationApprox` " +
                        "FROM `comms_events`",
                )
                db.execSQL("DROP TABLE `comms_events`")
                db.execSQL("ALTER TABLE `comms_events_new` RENAME TO `comms_events`")
            }
        }
    }
}
