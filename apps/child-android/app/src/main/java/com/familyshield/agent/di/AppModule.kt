package com.familyshield.agent.di

import android.app.admin.DevicePolicyManager
import android.content.Context
import com.familyshield.agent.enforcement.AndroidPackageFacts
import com.familyshield.agent.enforcement.PackageFacts
import com.familyshield.agent.network.UnlinkPolicy
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

    /**
     * One cached view of what the OS calls a package (issue #165): the lock and the block overlay ask
     * on every window event, so the role/HOME lookups are shared and invalidated together.
     */
    @Provides
    @Singleton
    fun providePackageFacts(@ApplicationContext context: Context): PackageFacts =
        AndroidPackageFacts(context)

    /**
     * Issue #465: the confirmation state lives with the poller, so it is one instance for the process.
     * Two answers at least a minute apart are what turn a `401 device_revoked` into an unlink, and a
     * second instance would restart that count on every poll.
     */
    @Provides
    @Singleton
    fun provideUnlinkPolicy(): UnlinkPolicy = UnlinkPolicy()
}
