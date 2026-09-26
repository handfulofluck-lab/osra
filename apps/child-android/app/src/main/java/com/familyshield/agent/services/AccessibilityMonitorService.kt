package com.familyshield.agent.services

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
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

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pkg = event?.packageName?.toString() ?: return
        if (pkg == packageName) return
        usage.recordForeground(pkg, System.currentTimeMillis())
        // Feature #2/#17: social/chat text capture for monitored apps (no-op elsewhere).
        social.onAccessibilityEvent(event)
        when (rules.evaluate(pkg)) {
            RuleRepository.Decision.BLOCK -> blocker.showBlockScreen(pkg)
            RuleRepository.Decision.TIME_LIMIT_REACHED -> blocker.showTimeLimitScreen(pkg)
            RuleRepository.Decision.ALLOW -> Unit
        }
    }
    override fun onInterrupt() = Unit
}
