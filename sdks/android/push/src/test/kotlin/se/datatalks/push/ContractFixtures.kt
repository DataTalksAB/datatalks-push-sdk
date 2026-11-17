package se.datatalks.push

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONArray
import org.json.JSONObject
import org.yaml.snakeyaml.Yaml
import java.io.File

/** The repository's `spec/` folder: the fixtures the SDK replays and the schemas its request bodies must match. */
internal object Contract {
    val dir = File(System.getProperty("spec.dir") ?: error("spec.dir isn't set: run the tests through Gradle."))

    const val APP_KEY = "dtpk_stg_live_Fixture0AppKey000000000000000000"
    const val DEVICE_SECRET = "Fixture0Secret000000000000000000"
    const val WRONG_SECRET = "Fixture0WrongSecret0000000000000"
    const val IDENTITY_TOKEN = "fixture.identity.token"

    fun fixtureNames(): Set<String> =
        File(dir, "fixtures").listFiles { file -> file.extension == "json" }!!.map { it.nameWithoutExtension }.toSet()

    fun fixture(name: String) = Fixture(JSONObject(File(dir, "fixtures/$name.json").readText()))

    private val schemas: Map<*, *> by lazy {
        val document = Yaml().load<Map<*, *>>(File(dir, "openapi/push-v1.yaml").readText())
        (document["components"] as Map<*, *>)["schemas"] as Map<*, *>
    }

    /** Fails, listing the problems, when [body] doesn't match the named schema of the OpenAPI document. */
    fun assertFits(schema: String, body: JSONObject) {
        val problems = mutableListOf<String>()
        checkObject(schemas[schema] as Map<*, *>, body, schema, problems)
        check(problems.isEmpty()) { "The body doesn't fit $schema: $problems" }
    }

    private fun resolve(schema: Map<*, *>): Map<*, *> {
        val ref = schema["\$ref"] as String? ?: return schema
        return schemas[ref.substringAfterLast('/')] as Map<*, *>
    }

    private fun checkObject(raw: Map<*, *>, body: JSONObject, path: String, problems: MutableList<String>) {
        val schema = resolve(raw)
        val parts = listOf(schema) + ((schema["allOf"] as List<*>?)?.map { resolve(it as Map<*, *>) } ?: emptyList())

        val known = mutableSetOf<String>()
        for (part in parts) {
            (part["required"] as List<*>?)?.forEach { name ->
                if (!body.has(name as String)) problems += "$path.$name is required"
            }

            (part["properties"] as Map<*, *>?)?.forEach { (name, property) ->
                known += name as String
                if (body.has(name)) checkValue(resolve(property as Map<*, *>), body.get(name), "$path.$name", problems)
            }
        }

        val closed = schema["additionalProperties"] == false || schema["unevaluatedProperties"] == false
        if (closed) {
            body.keys().forEach { name -> if (name !in known) problems += "$path.$name isn't in the contract" }
        }
    }

    private fun checkValue(schema: Map<*, *>, value: Any, path: String, problems: MutableList<String>) {
        when (schema["type"]) {
            "string" -> {
                if (value !is String) {
                    problems += "$path isn't a string"
                    return
                }

                (schema["maxLength"] as Int?)?.let { if (value.length > it) problems += "$path is over $it characters" }
                (schema["minLength"] as Int?)?.let { if (value.length < it) problems += "$path is under $it characters" }
                (schema["pattern"] as String?)?.let { if (!Regex(it).containsMatchIn(value)) problems += "$path doesn't match $it" }
                (schema["enum"] as List<*>?)?.let { if (value !in it) problems += "$path isn't one of $it" }
                FORMATS[schema["format"]]?.let { if (!it.matches(value)) problems += "$path isn't a ${schema["format"]}" }
            }

            "boolean" -> if (value !is Boolean) problems += "$path isn't a boolean"

            "object" -> if (value is JSONObject) checkObject(schema, value, path, problems) else problems += "$path isn't an object"

            "array" -> {
                if (value !is JSONArray) {
                    problems += "$path isn't an array"
                    return
                }

                (schema["minItems"] as Int?)?.let { if (value.length() < it) problems += "$path has under $it items" }
                (schema["maxItems"] as Int?)?.let { if (value.length() > it) problems += "$path has over $it items" }
                val items = (schema["items"] as Map<*, *>?)?.let(::resolve) ?: return
                for (index in 0 until value.length()) checkValue(items, value.get(index), "$path[$index]", problems)
            }
        }
    }

    private val FORMATS = mapOf(
        "uuid" to Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"),
        "date-time" to Regex("""\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})"""),
    )
}

/** One scenario of `spec/fixtures`: see its README for the placeholders. */
internal class Fixture(private val json: JSONObject) {
    private val steps: JSONArray = json.getJSONArray("steps")

    fun request(step: Int): JSONObject = steps.getJSONObject(step).getJSONObject("request")

    fun requestBody(step: Int): JSONObject = request(step).getJSONObject("body")

    /** The step's response, with placeholders replaced by the sample values the fixtures README gives for SDK tests. */
    fun response(step: Int): MockResponse {
        val answer = steps.getJSONObject(step).getJSONObject("response")
        val response = MockResponse().setResponseCode(answer.getInt("status"))
        answer.optJSONObject("headers")?.let { headers ->
            headers.keys().forEach { name ->
                val value = headers.getString(name)
                response.addHeader(name, if (value == "{{any}}") "1" else value)
            }
        }

        if (answer.has("body")) {
            val text = answer.get("body").toString()
                .replace("{{capture:device_secret}}", Contract.DEVICE_SECRET)
                .replace("{{uuid}}", "00000000-0000-5000-8000-000000000000")
                .replace("{{any}}", "fixture")
            response.setBody(text).addHeader("Content-Type", "application/json")
        }

        return response
    }

    /** Checks what the SDK sent against the step: method, path and headers exactly, and the body against the schema. */
    fun assertSent(step: Int, sent: RecordedRequest, schema: String? = null) {
        val expected = request(step)
        check(sent.method == expected.getString("method")) { "method: ${sent.method}, step $step" }
        check(sent.path == expected.getString("path")) { "path: ${sent.path}, step $step" }

        val headers = expected.getJSONObject("headers")
        check(sent.getHeader("X-DataTalks-App-Key") == Contract.APP_KEY) { "the app key, step $step" }
        check(sent.getHeader("X-DataTalks-SDK") == "datatalks-push-android/${BuildConfig.SDK_VERSION}") { "the SDK header, step $step" }
        val secret = when (headers.optString("X-DataTalks-Device-Secret")) {
            "" -> null
            "{{device_secret}}" -> Contract.DEVICE_SECRET
            "{{wrong_device_secret}}" -> Contract.WRONG_SECRET
            else -> error("A secret placeholder this test doesn't know, step $step")
        }
        check(sent.getHeader("X-DataTalks-Device-Secret") == secret) { "the device secret, step $step" }

        if (schema != null) {
            val body = JSONObject(sent.body.readUtf8())
            Contract.assertFits(schema, body)
            val fixtureBody = requestBody(step)
            for (name in FIELDS_THE_SDK_DECIDES) {
                if (fixtureBody.has(name)) {
                    val wanted = fixtureBody.get(name).toString().replace(Regex("""\{\{token:\w+}}"""), Contract.IDENTITY_TOKEN)
                    check(body.get(name).toString() == wanted) { "$name: ${body.opt(name)}, step $step" }
                }
            }
        }
    }

    private companion object {
        // Excludes device metadata, which comes from the test environment and can differ from the fixture.
        val FIELDS_THE_SDK_DECIDES = listOf("install_id", "platform", "fcm_token", "fcm_token_type", "external_id", "email", "identity_token", "marketing_opt_in")
    }
}
