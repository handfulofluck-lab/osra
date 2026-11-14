package com.familyshield.agent.di

import com.familyshield.agent.BuildConfig
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.ClientHeader
import com.familyshield.agent.network.ClientHeaderInterceptor
import com.familyshield.agent.network.DeviceAuthInterceptor
import com.familyshield.agent.network.DynamicBaseUrlInterceptor
import com.familyshield.agent.network.SignatureInterceptor
import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import java.util.concurrent.TimeUnit
import javax.inject.Singleton
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.converter.moshi.MoshiConverterFactory

/** Hilt wiring for the backend network stack (Moshi / OkHttp / Retrofit / ApiService). */
@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    // NOTE: placeholder build-time base (§14.2); DynamicBaseUrlInterceptor rewrites requests to the
    // tester-configured base URL from AgentSettings.
    internal const val API_BASE_URL: String = "https://api.osratech.com/"

    /** Moshi instance with Kotlin data-class support. */
    @Provides
    @Singleton
    fun provideMoshi(): Moshi = Moshi.Builder()
        .add(KotlinJsonAdapterFactory())
        .build()

    /** OkHttp client with dynamic base URL, device JWT auth, HMAC signing and basic logging. */
    @Provides
    @Singleton
    fun provideOkHttpClient(settings: AgentSettings): OkHttpClient = OkHttpClient.Builder()
        .addInterceptor(DynamicBaseUrlInterceptor { settings.baseUrlSync() })
        .addInterceptor(DeviceAuthInterceptor { settings.deviceTokenSync() })
        // ADR-0034 decision 4: name the build on every request. The Play and Full artefacts report their
        // own flavour, so the server can tell which store build a phone is running.
        .addInterceptor(
            ClientHeaderInterceptor {
                ClientHeader.value(
                    versionName = BuildConfig.VERSION_NAME,
                    versionCode = BuildConfig.VERSION_CODE,
                    flavour = if (BuildConfig.CAPTURE_CALL_SMS) ClientHeader.FLAVOUR_FULL else ClientHeader.FLAVOUR_PLAY,
                )
            },
        )
        .addInterceptor(SignatureInterceptor { settings.hmacSecretSync() })
        // osra-security#8 F4: request lines name the child and the device, so a release build logs nothing.
        .apply { if (BuildConfig.DEBUG) addInterceptor(HttpLoggingInterceptor().apply { level = HttpLoggingInterceptor.Level.BASIC }) }
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    /** Retrofit client targeting the backend. */
    @Provides
    @Singleton
    fun provideRetrofit(client: OkHttpClient, moshi: Moshi): Retrofit = Retrofit.Builder()
        .baseUrl(API_BASE_URL)
        .client(client)
        .addConverterFactory(MoshiConverterFactory.create(moshi))
        .build()

    /** Typed API surface. */
    @Provides
    @Singleton
    fun provideApiService(retrofit: Retrofit): ApiService = retrofit.create(ApiService::class.java)
}
