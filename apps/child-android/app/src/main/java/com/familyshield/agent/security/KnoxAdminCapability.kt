package com.familyshield.agent.security

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.util.Log
import java.lang.reflect.Method

/**
 * Reflection-only access to Samsung's Knox enterprise admin API (issue #186).
 *
 * Knox is not on the compile classpath and must not become a hard dependency: on every non-Samsung
 * device, and after any failed lookup or invocation, [probe] returns null so [AdminRemovalPolicy]
 * keeps the AOSP path. The API is reached through `EnterpriseDeviceManager` because that is the
 * frame Samsung's own `SecDeviceAdminAdd` uses (`EnterpriseDeviceManager.setActiveAdmin`); some
 * builds expose it on the nested Knox `DevicePolicyManager` instead, which is tried second.
 */
object KnoxAdminCapability {
    private const val TAG = "KnoxAdminCapability"
    private const val ENTERPRISE_CLASS = "com.samsung.android.knox.EnterpriseDeviceManager"

    fun probe(context: Context, component: ComponentName): KnoxAdminApi? {
        if (!Build.MANUFACTURER.equals("samsung", ignoreCase = true)) return null
        return runCatching { create(context, component) }
            .onFailure { Log.d(TAG, "Knox admin API unavailable: ${it.javaClass.simpleName}") }
            .getOrNull()
    }

    private fun create(context: Context, component: ComponentName): KnoxAdminApi? {
        val enterpriseClass = Class.forName(ENTERPRISE_CLASS, false, context.classLoader)
        val enterprise = enterpriseClass.getMethod("getInstance", Context::class.java)
            .invoke(null, context) ?: return null

        methodsOn(enterpriseClass)?.let { return ReflectiveKnoxAdminApi(enterprise, component, it) }

        val knoxDpm = enterpriseClass.getMethod("getDevicePolicyManager").invoke(enterprise)
            ?: return null
        return methodsOn(knoxDpm.javaClass)
            ?.let { ReflectiveKnoxAdminApi(knoxDpm, component, it) }
    }

    private fun methodsOn(type: Class<*>): SetActiveAdminMethods? {
        val twoArg = runCatching {
            type.getMethod("setActiveAdmin", ComponentName::class.java, Boolean::class.javaPrimitiveType)
        }.getOrNull()
        val threeArg = runCatching {
            type.getMethod(
                "setActiveAdmin",
                ComponentName::class.java,
                Boolean::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
            )
        }.getOrNull()
        return if (twoArg == null && threeArg == null) null else SetActiveAdminMethods(twoArg, threeArg)
    }

    private data class SetActiveAdminMethods(val twoArg: Method?, val threeArg: Method?)

    private class ReflectiveKnoxAdminApi(
        private val target: Any,
        private val component: ComponentName,
        private val methods: SetActiveAdminMethods,
    ) : KnoxAdminApi {

        override fun deactivate(): Boolean {
            methods.twoArg?.let { method ->
                val outcome = runCatching { method.invoke(target, component, false) }
                if (outcome.isSuccess) return outcome.getOrNull() != false
            }
            methods.threeArg?.let { method ->
                val outcome = runCatching { method.invoke(target, component, false, 0) }
                if (outcome.isSuccess) return outcome.getOrNull() != false
            }
            return false
        }
    }
}
