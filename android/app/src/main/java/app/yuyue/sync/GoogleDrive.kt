package app.yuyue.sync

import android.content.Context
import android.content.IntentSender
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import com.google.android.gms.tasks.Tasks
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * 同步 · Google Drive, as on Apple: the devices' files in the app's own hidden folder on the
 * reader's Drive (`appDataFolder`), which only 语阅 can see. Android asks the phone's Google
 * account for that one permission, in the system's own sheet; nothing about the account is kept
 * but its address, to show. 语阅's Android client sits in the same Google Cloud project as the
 * Apple one, so both see the same hidden folder.
 */
object DriveAuth {
    const val SCOPE = "https://www.googleapis.com/auth/drive.appdata"
    const val EMAIL = "sync.drive.email"

    private val request = AuthorizationRequest.builder().setRequestedScopes(listOf(Scope(SCOPE))).build()

    /** Asks for access: an access token straight away when already allowed, else what to show. */
    fun authorize(context: Context, done: (Result<Either>) -> Unit) {
        Identity.getAuthorizationClient(context).authorize(request)
            .addOnSuccessListener { r -> done(Result.success(either(r))) }
            .addOnFailureListener { done(Result.failure(it)) }
    }

    /** After the system's sheet: the token it gave. */
    fun token(context: Context, data: android.content.Intent?): String =
        Identity.getAuthorizationClient(context).getAuthorizationResultFromIntent(data).accessToken ?: throw Sync.SignedOut()

    sealed interface Either {
        class Token(val value: String) : Either
        class Ask(val sender: IntentSender) : Either
    }

    private fun either(r: AuthorizationResult): Either =
        r.pendingIntent?.takeIf { r.hasResolution() }?.let { Either.Ask(it.intentSender) } ?: Either.Token(r.accessToken ?: throw Sync.SignedOut())

    /** A token without asking, off the main thread; signed out when the reader must be asked again. */
    fun silentToken(context: Context): String = when (val e = either(Tasks.await(Identity.getAuthorizationClient(context).authorize(request), 30, TimeUnit.SECONDS))) {
        is Either.Token -> e.value
        is Either.Ask -> throw Sync.SignedOut()
    }
}

/** A folder on a sync service: file name → a tag that changes when the file does. */
interface SyncFolder {
    fun prepare()
    fun list(): Map<String, String>
    fun read(name: String): ByteArray
    fun write(name: String, data: ByteArray)
    fun upload(name: String, file: File)
    fun download(name: String, to: File)
}

class DriveFolder(private val context: Context) : SyncFolder {
    private val http = OkHttpClient.Builder().connectTimeout(30, TimeUnit.SECONDS).readTimeout(600, TimeUnit.SECONDS).writeTimeout(600, TimeUnit.SECONDS).build()
    private var token: String? = null
    private val ids = mutableMapOf<String, String>()

    override fun prepare() {
        token = DriveAuth.silentToken(context)
    }

    /** With the token; once more with a new one if Google says it has run out. */
    private fun send(build: () -> Request.Builder): Response {
        for (attempt in 0..1) {
            if (token == null || attempt > 0) token = DriveAuth.silentToken(context)
            val r = http.newCall(build().header("Authorization", "Bearer $token").build()).execute()
            if (r.code == 401 && attempt == 0) { r.close(); continue }
            if (r.code !in 200..299) { r.close(); throw Sync.Status(r.code) }
            return r
        }
        throw Sync.SignedOut()
    }

    override fun list(): Map<String, String> {
        val out = mutableMapOf<String, String>()
        ids.clear()
        var page: String? = null
        do {
            val url = "$API?spaces=appDataFolder&pageSize=1000&fields=nextPageToken,files(id,name,md5Checksum,modifiedTime)" + (page?.let { "&pageToken=$it" } ?: "")
            val json = send { Request.Builder().url(url) }.use { JSONObject(it.body!!.string()) }
            val files = json.optJSONArray("files")
            for (i in 0 until (files?.length() ?: 0)) {
                val f = files!!.getJSONObject(i)
                ids[f.getString("name")] = f.getString("id")
                out[f.getString("name")] = f.optString("md5Checksum").ifEmpty { f.optString("modifiedTime").ifEmpty { f.getString("id") } }
            }
            page = json.optString("nextPageToken").ifEmpty { null }
        } while (page != null)
        return out
    }

    private fun id(name: String): String {
        if (ids[name] == null) list()
        return ids[name] ?: throw Sync.Status(404)
    }

    override fun read(name: String): ByteArray = send { Request.Builder().url("$API/${id(name)}?alt=media") }.use { it.body!!.bytes() }

    override fun write(name: String, data: ByteArray) {
        val json = "application/json".toMediaType()
        ids[name]?.let { id ->
            send { Request.Builder().url("$UPLOAD/$id?uploadType=media").patch(data.toRequestBody(json)) }.close()
            return
        }
        // New: the name and the hidden folder, then the content, in one request.
        val body = MultipartBody.Builder().setType("multipart/related".toMediaType())
            .addPart(meta(name).toString().toRequestBody("application/json; charset=UTF-8".toMediaType()))
            .addPart(data.toRequestBody(json))
            .build()
        ids[name] = send { Request.Builder().url("$UPLOAD?uploadType=multipart&fields=id").post(body) }.use { JSONObject(it.body!!.string()).getString("id") }
    }

    /** 书文件: a resumable upload, the name and the hidden folder first when the file is new,
     *  then the content straight from disk. */
    override fun upload(name: String, file: File) {
        if (ids[name] == null) list()
        val type = type(name)
        val id = ids[name]
        val start = send {
            val b = Request.Builder().header("X-Upload-Content-Type", type)
            if (id != null) b.url("$UPLOAD/$id?uploadType=resumable").patch(ByteArray(0).toRequestBody(null))
            else b.url("$UPLOAD?uploadType=resumable&fields=id").post(meta(name).toString().toRequestBody("application/json; charset=UTF-8".toMediaType()))
        }
        val location = start.use { it.header("Location") } ?: throw Sync.Status(start.code)
        val made = http.newCall(Request.Builder().url(location).put(file.asRequestBody(type.toMediaType())).build()).execute()
        made.use {
            if (it.code !in 200..299) throw Sync.Status(it.code)
            runCatching { ids[name] = JSONObject(it.body!!.string()).getString("id") }
        }
    }

    override fun download(name: String, to: File) {
        send { Request.Builder().url("$API/${id(name)}?alt=media") }.use { r -> to.outputStream().use { out -> r.body!!.byteStream().copyTo(out) } }
    }

    /** The account's address, to show under 同步方式. */
    fun email(): String? = runCatching {
        send { Request.Builder().url("https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)") }.use { JSONObject(it.body!!.string()).getJSONObject("user").optString("emailAddress").ifEmpty { null } }
    }.getOrNull()

    private fun meta(name: String) = JSONObject().put("name", name).put("parents", org.json.JSONArray().put("appDataFolder"))

    private fun type(name: String) = when (name.substringAfterLast('.').lowercase()) {
        "epub" -> "application/epub+zip"
        "pdf" -> "application/pdf"
        "txt" -> "text/plain"
        "json" -> "application/json"
        else -> "application/octet-stream"
    }

    companion object {
        private const val API = "https://www.googleapis.com/drive/v3/files"
        private const val UPLOAD = "https://www.googleapis.com/upload/drive/v3/files"
    }
}

