package com.familyshield.agent.update

import com.squareup.moshi.JsonAdapter
import com.squareup.moshi.JsonReader
import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import okio.Buffer

data class FullUpdateManifest(
    val schema: Int,
    val packageName: String,
    val versionCode: Long,
    val versionName: String,
    val url: String,
    val sha256: String,
    val size: Long,
    val minSdk: Int,
    val releasedAt: String,
    val expiresAt: String,
    val keyId: String,
) {
    companion object {
        private val manifestMoshi: Moshi = Moshi.Builder().add(KotlinJsonAdapterFactory()).build()

        private val manifestAdapter: JsonAdapter<FullUpdateManifest> =
            manifestMoshi.adapter(FullUpdateManifest::class.java)

        fun parse(bytes: ByteArray): FullUpdateManifest? = try {
            val reader: JsonReader = JsonReader.of(Buffer().write(bytes))
            val manifest: FullUpdateManifest? = manifestAdapter.fromJson(reader)
            if (reader.peek() == JsonReader.Token.END_DOCUMENT) manifest else null
        } catch (e: Exception) {
            null
        }

        fun envelopeKeyId(bytes: ByteArray): String? = try {
            val reader: JsonReader = JsonReader.of(Buffer().write(bytes))
            if (reader.peek() != JsonReader.Token.BEGIN_OBJECT) {
                null
            } else {
                reader.beginObject()
                var keyId: String? = null
                while (reader.hasNext()) {
                    val name: String = reader.nextName()
                    if (name == "keyId" && reader.peek() == JsonReader.Token.STRING) {
                        keyId = reader.nextString()
                    } else {
                        reader.skipValue()
                    }
                }
                reader.endObject()
                if (reader.peek() == JsonReader.Token.END_DOCUMENT) keyId else null
            }
        } catch (e: Exception) {
            null
        }
    }
}
