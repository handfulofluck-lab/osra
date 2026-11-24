package com.familyshield.agent.di

import com.familyshield.agent.content.AccessibilitySearchCapture
import com.familyshield.agent.content.SearchCapture
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/** ADR-0039: Full flavor binds [SearchCapture] to [AccessibilitySearchCapture]. */
@Module
@InstallIn(SingletonComponent::class)
abstract class ContentBindingModule {
    @Binds
    @Singleton
    abstract fun searchCapture(impl: AccessibilitySearchCapture): SearchCapture
}
