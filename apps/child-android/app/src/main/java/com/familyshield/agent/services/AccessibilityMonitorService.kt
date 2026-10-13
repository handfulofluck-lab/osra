package com.familyshield.agent.services

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.content.pm.PackageManager
import android.view.accessibility.AccessibilityEvent
import androidx.core.content.ContextCompat
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.enforcement.AppBlocker
import com.familyshield.agent.social.SocialCapture
import com.familyshield.agent.telemetry.UsageReporter
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class AccessibilityMonitorService : AccessibilityService() {
    @Inject lateinit var rules: RuleRepository
    @Inject lateinit var blocker: AppBlocker
    @Inject lateinit var usage: UsageReporter
    @Inject lateinit var social: SocialCapture
    @Inject lateinit var settings: AgentSettings

    private var lastLocationCheckMs = 0L

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pkg = event?.packageName?.toString() ?: return
        if (pkg == packageName) return
        ensureLocationServiceRunning()
        usage.recordForeground(pkg, System.currentTimeMillis())
        // Feature #2/#17: social/chat text capture for monitored apps (no-op elsewhere).
        social.onAccessibilityEvent(event)
        when (rules.evaluate(pkg)) {
            RuleRepository.Decision.BLOCK -> blocker.showBlockScreen(pkg)
            RuleRepository.Decision.TIME_LIMIT_REACHED -> blocker.showTimeLimitScreen(pkg)
            RuleRepository.Decision.ALLOW -> Unit
        }
    }

    private fun ensureLocationServiceRunning() {
        val now = System.currentTimeMillis()
        if (now - lastLocationCheckMs < 60_000L) return
        lastLocationCheckMs = now

        if (!LocationService.isServiceRunning && settings.deviceTokenSync() != null) {
            val hasFine = ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            val hasCoarse = ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
            if (hasFine || hasCoarse) {
                try {
                    ContextCompat.startForegroundService(this, Intent(this, LocationService::class.java))
                } catch (e: Exception) {
                    // Gracefully ignore if OS restricts background FGS start
                }
            }
        }
    }
    override fun onInterrupt() = Unit
}
