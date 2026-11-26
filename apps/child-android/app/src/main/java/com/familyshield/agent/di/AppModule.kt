package com.familyshield.agent.di

import android.app.admin.DevicePolicyManager
import android.content.Context
import com.familyshield.agent.enforcement.AndroidPackageFacts
import com.familyshield.agent.enforcement.PackageFacts
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.network.UnlinkPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
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
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Provides
    @Singleton
    fun provideUnlinkPolicy(settings: AgentSettings): UnlinkPolicy {
        // Issue #1162: the persisted first answer, so a process death between the two `device_revoked` answers
        // no longer restarts the clock. The write is fire-and-forget: the poll must never wait on DataStore.
        // One worker, so a `persist(ms)` and a fast `persist(null)` cannot land out of order and leave a stale
        // timestamp on disk (Ahmed's #1164 nit). Bounded by the expiry either way, but implicit ordering is
        // the kind of thing that only looks fine until it doesn't.
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1))
        return UnlinkPolicy(
            persistedFirstRevokedAtMs = settings.firstRevokedAtMsSync(),
            persist = { ms -> scope.launch { settings.saveFirstRevokedAtMs(ms) } },
        )
    }
}
