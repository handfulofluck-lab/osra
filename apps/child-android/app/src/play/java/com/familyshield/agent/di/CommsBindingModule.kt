package com.familyshield.agent.di

import com.familyshield.agent.comms.CommsCapture
import com.familyshield.agent.comms.NoopCommsCapture
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * ADR-0021: the $flavor build binds [CommsCapture] to NoopCommsCapture. The other flavour has its own
 * module with the same class name in its own source set, so exactly one binding exists per variant.
 */
@Module
@InstallIn(SingletonComponent::class)
abstract class CommsBindingModule {
    @Binds
    @Singleton
    abstract fun commsCapture(impl: NoopCommsCapture): CommsCapture
}
