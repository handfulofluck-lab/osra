package com.familyshield.agent

import android.app.Application
import com.familyshield.agent.di.WorkerEntryPoint
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class FamilyShieldApp : Application() {

    override fun onCreate() {
        super.onCreate()
        // Feature #6: start the call/SMS content observers as early as possible (they no-op until
        // READ_CALL_LOG/READ_SMS are granted, then pick up automatically).
        EntryPointAccessors.fromApplication(this, WorkerEntryPoint::class.java)
            .commsLogger()
            .start()
    }
}
