package com.familyshield.agent.di

import com.familyshield.agent.update.NoopUpdateCheckScheduler
import com.familyshield.agent.update.UpdateCheckScheduler
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * ADR-0039 D5: the Play artefact is updated by Google Play and must never download or install an APK, so
 * it binds the no-op scheduler. The Full flavour has its own module with the same class name in its own
 * source set, so exactly one binding exists per variant.
 */
@Module
@InstallIn(SingletonComponent::class)
abstract class UpdateBindingModule {
    @Binds
    @Singleton
    abstract fun updateCheckScheduler(impl: NoopUpdateCheckScheduler): UpdateCheckScheduler
}
