package com.familyshield.agent.di

import android.app.admin.DevicePolicyManager
import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/** Hilt wiring for Android system services. */
@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    /** DevicePolicyManager used for device-owner lockNow(). */
    @Provides
    @Singleton
    fun provideDevicePolicyManager(@ApplicationContext context: Context): DevicePolicyManager =
        context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
}
