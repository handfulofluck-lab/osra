package com.familyshield.agent

import android.app.Application
import com.familyshield.agent.di.WorkerEntryPoint
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.android.HiltAndroidApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

@HiltAndroidApp
class FamilyShieldApp : Application() {

    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        // Feature #6: start the call/SMS content observers as early as possible. Issue #229: a stream
        // whose permission is missing is not registered here; CommsCapture.onPermissionsChanged()
        // retries the registration when the grant arrives, without a reboot.
        EntryPointAccessors.fromApplication(this, WorkerEntryPoint::class.java)
            .commsCapture()
            .start()
        // Issue #465 review: an unlink is idempotent, so a start after a half-finished one finishes it.
        // Without this, a death between `clearPairing()` and dropping device admin leaves an unpaired
        // phone holding a grant nobody can remove — no device id means no poll ever calls the unlinker.
        val entry = EntryPointAccessors.fromApplication(this, WorkerEntryPoint::class.java)
        appScope.launch {
            if (entry.agentSettings().unlinkPending()) entry.deviceUnlinker().unlink()
        }
    }
}
