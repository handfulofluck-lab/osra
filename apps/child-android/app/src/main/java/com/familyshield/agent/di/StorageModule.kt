package com.familyshield.agent.di

import android.content.Context
import androidx.room.Room
import com.familyshield.agent.data.db.AgentStateDao
import com.familyshield.agent.data.db.CommsEventDao
import com.familyshield.agent.data.db.FamilyShieldDatabase
import com.familyshield.agent.data.db.PendingPingDao
import com.familyshield.agent.data.db.UsageEventDao
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/** Hilt wiring for the Room database and its DAOs. */
@Module
@InstallIn(SingletonComponent::class)
object StorageModule {

    /** The app-wide Room database. */
    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): FamilyShieldDatabase =
        Room.databaseBuilder(context, FamilyShieldDatabase::class.java, "familyshield.db")
            .fallbackToDestructiveMigration()
            .build()

    /** DAO for unsent location pings. */
    @Provides
    fun providePendingPingDao(db: FamilyShieldDatabase): PendingPingDao = db.pendingPingDao()

    /** DAO for raw usage events. */
    @Provides
    fun provideUsageEventDao(db: FamilyShieldDatabase): UsageEventDao = db.usageEventDao()

    /** DAO for agent key/value state. */
    @Provides
    fun provideAgentStateDao(db: FamilyShieldDatabase): AgentStateDao = db.agentStateDao()

    /** DAO for unsent call/SMS events (Feature #6). */
    @Provides
    fun provideCommsEventDao(db: FamilyShieldDatabase): CommsEventDao = db.commsEventDao()
}
