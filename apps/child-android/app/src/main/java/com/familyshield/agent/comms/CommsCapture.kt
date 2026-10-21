package com.familyshield.agent.comms

/**
 * ADR-0021: call/SMS capture is a **Full-build** capability, so the rest of the app talks to this
 * interface instead of the implementation. `play` binds [NoopCommsCapture]; `full` binds
 * `CommsLogger` (which carries the permissions, the content observers and the upload path).
 *
 * The decision logic (`CommsAccessPolicy`, `ScanQueuePolicy`) stays in `main` and is unit-tested there —
 * what moves per flavour is the Android binding, exactly as with the notification listener.
 */
interface CommsCapture {
    /** Register the observers that are allowed now and start the flush loop. Idempotent. */
    fun start()

    /**
     * Issue #229: re-read the call-log/SMS grants, register any observer that has become allowed and
     * run one harvest for each registered stream. Called on the permission result, on the launcher
     * screen's `onResume` and at the top of the 5-minute loop, so a later grant takes effect without
     * a process restart.
     */
    fun onPermissionsChanged()

    /** Flush whatever is buffered; called by the telemetry worker as a backstop. */
    suspend fun flush()
}
