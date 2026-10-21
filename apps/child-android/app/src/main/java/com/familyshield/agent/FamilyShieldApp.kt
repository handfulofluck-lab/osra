package com.familyshield.agent

import android.app.Application
import com.familyshield.agent.di.WorkerEntryPoint
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class FamilyShieldApp : Application() {

    override fun onCreate() {
        super.onCreate()
        // Feature #6: start the call/SMS content observers as early as possible. Issue #229: a stream
        // whose permission is missing is not registered here; CommsCapture.onPermissionsChanged()
        // retries the registration when the grant arrives, without a reboot.
        EntryPointAccessors.fromApplication(this, WorkerEntryPoint::class.java)
            .commsCapture()
            .start()
    }
}
