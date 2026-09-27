package org.localsend.localsend_app

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.RejectedExecutionException


private const val CHANNEL = "org.localsend.localsend_app/localsend"
private const val REQUEST_CODE_PICK_DIRECTORY = 1
private const val REQUEST_CODE_PICK_DIRECTORY_PATH = 2
private const val REQUEST_CODE_PICK_FILE = 3
private const val REQUEST_CODE_LOCAL_NETWORK = 4

// Not available as a constant in compileSdk 36.
private const val PERMISSION_ACCESS_LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
private const val API_LEVEL_ANDROID_17 = 37

class MainActivity : FlutterActivity() {
    private val folderSelection by lazy { AndroidFolderSelection(applicationContext) }
    private val fileSelection by lazy { AndroidFileSelection(applicationContext) }
    private var networkRouteObserver: Long? = null
    private var workspaceDocumentsOwner: Long? = null
    private val workspaceDocuments get() = AndroidSafWorkspace.get(applicationContext)
    @Volatile private var safActivityClosed = false
    private val safManager get() = AndroidSafReceiveTransaction.manager(applicationContext)
    private val safTransactions get() = safManager.transactions

    // Keep ownership across the worker-to-UI boundary. A destroyed Activity never leaks a detached FD.
    private data class SafOpenedDocument(val descriptor: ParcelFileDescriptor, val uri: String? = null)

    private fun discardUnsentPair(pair: AndroidSafReceiveTransaction.OpenedPair) {
        pair.close()
        // Both independent transport handles remained local; no Rust writer acquired them.
        // Reserve a separate bounded dispatcher so a full queue of new opens
        // cannot discard cleanup. It uses the same operation lock as provider work.
        try {
            safCleanupWorker.execute {
                synchronized(safOperationLock) {
                    try { safTransactions.abortReceiving(pair.transactionId, pair.lease) }
                    catch (error: Exception) { android.util.Log.w("LegnaSend", "Unsent receive cleanup retained its journal", error) }
                }
            }
        } catch (error: RejectedExecutionException) {
            // The adapter admits at most 64 live pairs and this queue reserves
            // 64 cleanup slots. Unexpected duplicate saturation retains evidence.
            android.util.Log.w("LegnaSend", "Receive cleanup queue saturated; journal retained", error)
        }
    }

    private fun discardRecoveryBinding(binding: AndroidSafReceiveTransaction.IdentityBinding) {
        binding.close()
        try {
            safCleanupWorker.execute { synchronized(safOperationLock) {
                try { safManager.discardBinding(binding) }
                catch (error: Exception) { android.util.Log.w("LegnaSend", "Recovery source claim retained", error) }
            } }
        } catch (error: RejectedExecutionException) {
            android.util.Log.w("LegnaSend", "Recovery source cleanup deferred", error)
        }
    }

    private fun discardRecoveryCleanup(preparation: AndroidSafReceiveTransaction.CleanupPreparation) {
        preparation.close()
        try {
            safCleanupWorker.execute { synchronized(safOperationLock) {
                try { safManager.finishRecoveryCleanup(preparation.transactionId, preparation.sourceTransactionId) }
                catch (error: Exception) { android.util.Log.w("LegnaSend", "Recovery cleanup witness close deferred", error) }
            } }
        } catch (error: RejectedExecutionException) {
            android.util.Log.w("LegnaSend", "Recovery cleanup dispatcher busy", error)
        }
    }

    private fun discardPublishedStaging(preparation: AndroidSafReceiveTransaction.StagingPreparation) {
        try { preparation.close() }
        finally {
            try {
                safCleanupWorker.execute { synchronized(safOperationLock) {
                    try { safManager.finishPublishedStagingCleanup(preparation.transactionId, preparation.cleanupId) }
                    catch (error: Exception) { android.util.Log.w("LegnaSend", "Published staging witness close deferred: ${error.javaClass.simpleName}") }
                } }
            } catch (_: RejectedExecutionException) {
                android.util.Log.w("LegnaSend", "Published staging witness dispatcher busy")
            }
        }
    }

    private fun discardPublicationReconcile(preparation: AndroidSafReceiveTransaction.PublicationPreparation) {
        try { preparation.close() }
        finally {
            try {
                safCleanupWorker.execute { synchronized(safOperationLock) {
                    try { safManager.finishPublicationReconcile(preparation.transactionId, preparation.reconciliationId) }
                    catch (error: Exception) { android.util.Log.w("LegnaSend", "Publication witness close deferred: ${error.javaClass.simpleName}") }
                } }
            } catch (error: RejectedExecutionException) {
                android.util.Log.w("LegnaSend", "Publication witness dispatcher busy")
            }
        }
    }

    private fun deliverSaf(result: MethodChannel.Result, value: Any?) {
        if (value is AndroidSafReceiveTransaction.StagingPreparation) {
            if (safActivityClosed || isDestroyed || isFinishing) {
                discardPublishedStaging(value)
                result.error("ACTIVITY_CLOSED", "Activity closed before published staging cleanup handoff", null)
                return
            }
            var detached: Int? = null
            try {
                detached = value.descriptor.detachFd()
                result.success(mapOf("transactionId" to value.transactionId, "cleanupId" to value.cleanupId,
                    "length" to value.length, "sha256" to value.sha256, "descriptor" to detached))
            } catch (error: Exception) {
                try { detached?.let { ParcelFileDescriptor.adoptFd(it).close() } }
                finally { discardPublishedStaging(value) }
                android.util.Log.w("LegnaSend", "Published staging cleanup handoff failed: ${error.javaClass.simpleName}")
            } finally { value.close() }
            return
        }

        if (value is AndroidSafReceiveTransaction.PublicationPreparation) {
            if (safActivityClosed || isDestroyed || isFinishing) {
                discardPublicationReconcile(value)
                result.error("ACTIVITY_CLOSED", "Activity closed before publication reconciliation handoff", null)
                return
            }
            var detached: Int? = null
            try {
                detached = value.descriptor.detachFd()
                result.success(mapOf("transactionId" to value.transactionId, "reconciliationId" to value.reconciliationId,
                    "size" to value.size, "sha256" to value.sha256, "fileDescriptor" to detached))
            } catch (error: Exception) {
                try { detached?.let { ParcelFileDescriptor.adoptFd(it).close() } }
                finally { discardPublicationReconcile(value) }
                android.util.Log.w("LegnaSend", "Publication reconciliation handoff failed: ${error.javaClass.simpleName}")
            } finally { value.close() }
            return
        }

        if (value is AndroidSafReceiveTransaction.CleanupPreparation) {
            if (safActivityClosed || isDestroyed || isFinishing) {
                discardRecoveryCleanup(value)
                result.error("ACTIVITY_CLOSED", "Activity closed before recovery cleanup handoff", null)
                return
            }
            var detached: Int? = null
            try {
                detached = value.descriptor.detachFd()
                result.success(mapOf("transactionId" to value.transactionId, "sourceTransactionId" to value.sourceTransactionId,
                    "sourceLength" to value.sourceLength, "sourceSha256" to value.sourceSha256, "descriptor" to detached))
            } catch (error: Exception) {
                detached?.let { ParcelFileDescriptor.adoptFd(it).close() }
                discardRecoveryCleanup(value)
                android.util.Log.w("LegnaSend", "Recovery cleanup descriptor handoff failed", error)
            } finally { value.close() }
            return
        }

        if (value is AndroidSafReceiveTransaction.IdentityBinding) {
            if (safActivityClosed || isDestroyed || isFinishing) {
                discardRecoveryBinding(value)
                result.error("ACTIVITY_CLOSED", "Activity closed before recovery handoff", null)
                return
            }
            var detached: Int? = null
            try {
                val reply = mutableMapOf<String, Any?>("transactionId" to value.transactionId,
                    "coreAttemptId" to value.coreAttemptId, "bound" to true)
                value.source?.let {
                    detached = it.detachFd()
                    reply["recovery"] = mapOf("transactionId" to value.sourceId, "identityJson" to value.identityJson, "sourceFd" to detached)
                }
                result.success(reply)
            } catch (error: Exception) {
                detached?.let { ParcelFileDescriptor.adoptFd(it).close() }
                discardRecoveryBinding(value)
                android.util.Log.w("LegnaSend", "Recovery source handoff failed", error)
            } finally { value.close() }
            return
        }

        if (value is AndroidSafReceiveTransaction.OpenedPair) {
            if (safActivityClosed || isDestroyed || isFinishing) {
                discardUnsentPair(value)
                result.error("ACTIVITY_CLOSED", "The receive activity closed before descriptor handoff", null)
                return
            }
            var cacheFd: Int? = null
            var stagingFd: Int? = null
            try {
                cacheFd = value.cache.detachFd()
                stagingFd = value.staging.detachFd()
                result.success(mapOf("transactionId" to value.transactionId, "lease" to value.lease,
                    "cacheFd" to cacheFd, "stagingFd" to stagingFd))
            } catch (error: Exception) {
                cacheFd?.let { ParcelFileDescriptor.adoptFd(it).close() }
                stagingFd?.let { ParcelFileDescriptor.adoptFd(it).close() }
                discardUnsentPair(value)
                android.util.Log.w("LegnaSend", "Receive pair reply failed; transport descriptors closed", error)
            } finally { value.close() }
            return
        }
        if (value !is SafOpenedDocument) {
            result.success(value)
            return
        }
        value.descriptor.use { descriptor ->
            if (safActivityClosed || isDestroyed || isFinishing) {
                result.error("ACTIVITY_CLOSED", "The receive activity was closed before descriptor handoff", null)
                return
            }
            val fd = descriptor.detachFd()
            try {
                result.success(if (value.uri == null) fd else mapOf("uri" to value.uri, "fd" to fd))
            } catch (error: Exception) {
                ParcelFileDescriptor.adoptFd(fd).close()
                android.util.Log.w("LegnaSend", "Descriptor reply failed; local ownership closed", error)
            }
        }
    }

    private fun runSaf(result: MethodChannel.Result, allowClosed: Boolean = false, action: () -> Any?) {
        try {
            val worker = if (allowClosed) safCleanupWorker else safWorker
            worker.execute {
                synchronized(safOperationLock) {
                    if (!allowClosed && (safActivityClosed || isDestroyed || isFinishing)) {
                        runOnUiThread { result.error("ACTIVITY_CLOSED", "The receive activity was closed before provider access", null) }
                        return@execute
                    }
                    try {
                        val value = action()
                        try {
                            runOnUiThread { deliverSaf(result, value) }
                        } catch (error: Exception) {
                            if (value is AndroidSafReceiveTransaction.StagingPreparation) discardPublishedStaging(value)
                            if (value is AndroidSafReceiveTransaction.PublicationPreparation) discardPublicationReconcile(value)
                            if (value is AndroidSafReceiveTransaction.CleanupPreparation) discardRecoveryCleanup(value)
                            if (value is AndroidSafReceiveTransaction.IdentityBinding) discardRecoveryBinding(value)
                            if (value is SafOpenedDocument) value.descriptor.close()
                            if (value is AndroidSafReceiveTransaction.OpenedPair) discardUnsentPair(value)
                            throw error
                        }
                    } catch (e: SafReceiveTransaction.Failure) {
                        runOnUiThread { result.error(e.code, e.message, null) }
                    } catch (e: SafDirectoryResolver.Failure) {
                        runOnUiThread { result.error(e.code, e.message, null) }
                    } catch (e: SecurityException) {
                        runOnUiThread { result.error("PERMISSION_DENIED", "Select the directory again to grant access", null) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("DIRECTORY_UNAVAILABLE", "Directory provider is unavailable", null) }
                    }
                }
            }
        } catch (e: RejectedExecutionException) {
            result.error("BUSY", "Directory operations are busy; retry", null)
        }
    }

    override fun onDestroy() {
        folderSelection.close()
        fileSelection.close()
        val pickerReply = pendingResult
        pendingResult = null
        pickerReply?.error("cancelled", "The activity closed while selecting files", null)
        safActivityClosed = true
        workspaceDocumentsOwner?.let { workspaceDocuments.detach(it) }
        workspaceDocumentsOwner = null
        NetworkRouteReader.stopObserving(networkRouteObserver)
        super.onDestroy()
    }

    private var pendingDirectoryWritable = false
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    /// share_handler drops share intents arriving via onNewIntent while the Dart side
    /// is not subscribed to its media stream yet, which happens when this singleTask
    /// activity is relaunched into an existing task while the app is still starting.
    /// Hold such intents back until Dart reports readiness ("shareIntentReady"), then
    /// replay them through the regular plugin path.
    private val pendingShareIntents = mutableListOf<Intent>()
    private var shareIntentReady = false

    override fun onNewIntent(intent: Intent) {
        if (!shareIntentReady && (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE)) {
            pendingShareIntents.add(intent)
            return
        }
        super.onNewIntent(intent)
    }

    private fun onShareIntentReady() {
        shareIntentReady = true
        val pending = pendingShareIntents.toList()
        pendingShareIntents.clear()
        for (intent in pending) {
            super.onNewIntent(intent)
        }
    }

    // Overriding the static methods we need from the Java class, as described
    // in the documentation of `FlutterActivity.NewEngineIntentBuilder`
    companion object {
        // Serialize provider/journal operations across Activity destruction and recreation.
        private val safOperationLock = Any()
        private val safWorker = ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS, ArrayBlockingQueue<Runnable>(64))
        private val safCleanupWorker = ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS, ArrayBlockingQueue<Runnable>(64))

        fun withNewEngine(): NewEngineIntentBuilder {
            return NewEngineIntentBuilder(MainActivity::class.java)
        }

        fun createDefaultIntent(launchContext: Context): Intent {
            return withNewEngine().build(launchContext)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        workspaceDocumentsOwner = workspaceDocuments.attach()
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "$CHANNEL/network-routes").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                NetworkRouteReader.stopObserving(networkRouteObserver)
                var owner: Long? = null
                owner = NetworkRouteReader.observe(applicationContext) { snapshot ->
                    runOnUiThread { if (!isDestroyed && owner == networkRouteObserver) sink.success(snapshot) }
                }
                networkRouteObserver = owner
                sink.success(NetworkRouteReader.snapshot(applicationContext))
            }
            override fun onCancel(arguments: Any?) {
                NetworkRouteReader.stopObserving(networkRouteObserver)
                networkRouteObserver = null
            }
        })
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "networkSignals" -> result.success(NetworkSignalReader.read(this))

                "workspaceDocumentWrite" -> {
                    val owner = workspaceDocumentsOwner
                    if (owner == null || isDestroyed || isFinishing) result.error("cancelled", "cancelled", null)
                    else AndroidSafWorkspaceWrite.get(applicationContext).request(owner, call.argument<String>("request"), result)
                }
                "workspaceDocuments" -> {
                    val owner = workspaceDocumentsOwner
                    if (owner == null || isDestroyed || isFinishing) {
                        result.error("cancelled", "cancelled", null)
                    } else {
                        workspaceDocuments.request(owner, call.argument<String>("request"), result)
                    }
                }

                "pickDirectory" -> {
                    if (pendingResult != null) {
                        result.error("BUSY", "A picker is already open", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    openDirectoryPicker(onlyPath = false)
                }

                "pickFiles" -> {
                    if (pendingResult != null) {
                        result.error("BUSY", "A picker is already open", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    openFilePicker()
                }

                "pickDirectoryPath" -> {
                    if (pendingResult != null) {
                        result.error("BUSY", "A picker is already open", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingDirectoryWritable = call.argument<Boolean>("requireWrite") == true
                    openDirectoryPicker(onlyPath = true)
                }

                "resolveReceiveDirectory" -> {
                    val tree = call.argument<String>("treeUri")
                    val components = call.argument<List<String>>("components")
                    if (tree == null || components == null) {
                        result.error("INVALID_ARGUMENT", "Missing treeUri or components", null)
                    } else {
                        runSaf(result) { AndroidSafDirectory(contentResolver).resolve(tree, components) }
                    }
                }

                "beginSafReceiveTransaction" -> {
                    val fields = listOf("treeUri", "parentUri", "fileName", "sessionId", "fileId", "attemptId").map { call.argument<String>(it) }
                    if (fields.any { it == null }) {
                        result.error("INVALID_ARGUMENT", "Missing receive transaction fields", null)
                    } else {
                        runSaf(result) {
                            val record = safTransactions.begin(fields[0]!!, fields[1]!!, fields[2]!!, fields[3]!!, fields[4]!!, fields[5]!!)
                            mapOf("transactionId" to record.id, "state" to "ready", "cacheUri" to record.cache.uri,
                                "stagingUri" to record.staging.uri, "capabilities" to mapOf("readWrite" to true, "seek" to true, "length" to true, "lock" to true))
                        }
                    }
                }

                "reconcileSafReceiveTransactions" -> {
                    val limit = call.argument<Number>("limit")?.toInt() ?: 32
                    runSaf(result) { safManager.reconcile(limit) }
                }

                "openSafReceiveTransaction" -> {
                    val fields = listOf("transactionId", "sessionId", "fileId", "attemptId").map { call.argument<String>(it) }
                    if (fields.any { it == null }) result.error("INVALID_ARGUMENT", "Missing receive handoff fields", null)
                    else runSaf(result) {
                        val record = safTransactions.openReceive(fields[0]!!, fields[1]!!, fields[2]!!, fields[3]!!)
                        try { safManager.backend.duplicatePair(record) }
                        catch (error: Exception) {
                            try { safTransactions.abortReceiving(record.id, record.lease) } catch (_: Exception) { }
                            throw error
                        }
                    }
                }

                "bindSafReceiveCacheIdentity" -> {
                    val fields = listOf("transactionId", "lease", "coreAttemptId", "identityJson").map { call.argument<String>(it) }
                    if (fields.any { it == null }) result.error("INVALID_ARGUMENT", "Missing cache identity binding", null)
                    else runSaf(result) {
                        safManager.bind(fields[0]!!, fields[1]!!, fields[2]!!, fields[3]!!)
                    }
                }

                "completeSafReceiveRecovery" -> {
                    val fields = listOf("transactionId", "lease", "coreAttemptId", "sourceTransactionId").map { call.argument<String>(it) }
                    val sourceLength = call.argument<Any>("sourceLength")
                    val sourceSha256 = call.argument<String>("sourceSha256")
                    if (fields.any { it == null } || (sourceLength !is Long && sourceLength !is Int) || sourceSha256 == null)
                        result.error("INVALID_ARGUMENT", "Missing recovery completion identity or container proof", null)
                    else runSaf(result) {
                        safManager.completeRecovery(fields[0]!!, fields[1]!!, fields[2]!!, fields[3]!!, (sourceLength as Number).toLong(), sourceSha256)
                        mapOf("transactionId" to fields[0], "coreAttemptId" to fields[2], "sourceTransactionId" to fields[3], "complete" to true)
                    }
                }

                "prepareSafPublishedStagingCleanup" -> {
                    val id = call.argument<String>("transactionId")
                    if (id == null) result.error("INVALID_ARGUMENT", "Missing published staging transaction", null)
                    else runSaf(result) { safManager.preparePublishedStagingCleanup(id) }
                }
                "deleteSafPublishedStagingCleanup" -> {
                    val id = call.argument<String>("transactionId")
                    val token = call.argument<String>("cleanupId")
                    if (id == null || token == null) result.error("INVALID_ARGUMENT", "Missing published staging cleanup identity", null)
                    else runSaf(result) { safManager.deletePublishedStagingCleanup(id, token) }
                }
                "finishSafPublishedStagingCleanup" -> {
                    val id = call.argument<String>("transactionId")
                    val token = call.argument<String>("cleanupId")
                    if (id == null || token == null) result.error("INVALID_ARGUMENT", "Missing published staging cleanup identity", null)
                    else runSaf(result, allowClosed = true) { safManager.finishPublishedStagingCleanup(id, token); null }
                }

                "prepareSafReceivePublicationReconcile" -> {
                    val id = call.argument<String>("transactionId")
                    if (id == null) result.error("INVALID_ARGUMENT", "Missing publication transaction", null)
                    else runSaf(result) { safManager.preparePublicationReconcile(id) }
                }
                "confirmSafReceivePublicationReconcile" -> {
                    val id = call.argument<String>("transactionId")
                    val token = call.argument<String>("reconciliationId")
                    if (id == null || token == null) result.error("INVALID_ARGUMENT", "Missing publication reconciliation identity", null)
                    else runSaf(result) {
                        safManager.confirmPublicationReconcile(id, token)
                        mapOf("transactionId" to id, "reconciled" to true)
                    }
                }
                "finishSafReceivePublicationReconcile" -> {
                    val id = call.argument<String>("transactionId")
                    val token = call.argument<String>("reconciliationId")
                    if (id == null || token == null) result.error("INVALID_ARGUMENT", "Missing publication reconciliation identity", null)
                    else runSaf(result, allowClosed = true) { safManager.finishPublicationReconcile(id, token); null }
                }

                "prepareSafRecoveryCleanup" -> {
                    val id = call.argument<String>("transactionId")
                    val lease = call.argument<String>("lease")
                    if (id == null || lease == null) result.error("INVALID_ARGUMENT", "Missing cleanup target", null)
                    else runSaf(result) { safManager.prepareRecoveryCleanup(id, lease) }
                }
                "deleteSafRecoveryCleanup" -> {
                    val fields = listOf("transactionId", "lease", "sourceTransactionId").map { call.argument<String>(it) }
                    if (fields.any { it == null }) result.error("INVALID_ARGUMENT", "Missing cleanup identity", null)
                    else runSaf(result) { safManager.deleteRecoveryCleanup(fields[0]!!, fields[1]!!, fields[2]!!) }
                }
                "finishSafRecoveryCleanup" -> {
                    val id = call.argument<String>("transactionId")
                    val source = call.argument<String>("sourceTransactionId")
                    if (id == null || source == null) result.error("INVALID_ARGUMENT", "Missing cleanup witness identity", null)
                    else runSaf(result, allowClosed = true) { safManager.finishRecoveryCleanup(id, source); null }
                }

                "publishSafReceiveTransaction" -> {
                    val id = call.argument<String>("transactionId")
                    val lease = call.argument<String>("lease")
                    val attempt = call.argument<String>("coreAttemptId")
                    val size = call.argument<Number>("size")?.toLong()
                    val sha256 = call.argument<String>("sha256")
                    if (id == null || lease == null || attempt == null || size == null || sha256 == null) {
                        result.error("INVALID_ARGUMENT", "Missing verified publication receipt", null)
                    } else runSaf(result) {
                        val record = safTransactions.publish(id, lease, attempt, size, sha256)
                        mapOf("transactionId" to record.id, "uri" to record.output.uri, "size" to record.size, "sha256" to record.sha256)
                    }
                }

                "releaseSafReceiveTransaction" -> {
                    val id = call.argument<String>("transactionId")
                    val lease = call.argument<String>("lease")
                    if (id == null || lease == null) result.error("INVALID_ARGUMENT", "Missing receive release identity", null)
                    else runSaf(result, allowClosed = true) {
                        // The durable native state wins over an unacknowledged/late core flag.
                        // abortReceiving preserves an already PUBLISHED final document.
                        val report = safManager.release(id, lease)
                        mapOf("transactionId" to report.transactionId, "deleted" to report.deleted,
                            "retained" to report.retained, "reasons" to report.reasons, "complete" to report.complete)
                    }
                }

                "abortSafReceiveTransaction" -> {
                    val id = call.argument<String>("transactionId")
                    if (id == null) {
                        result.error("INVALID_ARGUMENT", "Missing transactionId", null)
                    } else {
                        runSaf(result) {
                            val report = safTransactions.abort(id)
                            mapOf("transactionId" to report.transactionId, "deleted" to report.deleted,
                                "retained" to report.retained, "reasons" to report.reasons, "complete" to report.complete)
                        }
                    }
                }

                "getFileDescriptor" -> handleGetFileDescriptor(call, result)

                "createFile" -> handleCreateFile(call, result)

                "openFileForWriting" -> handleOpenFileForWriting(call, result)

                "openContentUri" -> {
                    openUri(context, call.argument<String>("uri")!!)
                    result.success(null)
                }

                "openGallery" -> {
                    openGallery()
                    result.success(null)
                }

                "shareIntentReady" -> {
                    onShareIntentReady()
                    result.success(null)
                }

                "isAnimationsEnabled" -> {
                    result.success(isAnimationsEnabled())
                }

                "getDownloadsDirectory" -> {
                    result.success(getDownloadsDirectory())
                }

                "requestLocalNetworkPermission" -> {
                    if (hasLocalNetworkPermission()) {
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        requestPermissions(arrayOf(PERMISSION_ACCESS_LOCAL_NETWORK), REQUEST_CODE_LOCAL_NETWORK)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /// Android 17+ gates local network access behind a runtime permission; older versions grant it implicitly.
    private fun hasLocalNetworkPermission(): Boolean {
        if (Build.VERSION.SDK_INT < API_LEVEL_ANDROID_17) {
            return true
        }
        return checkSelfPermission(PERMISSION_ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE_LOCAL_NETWORK) {
            pendingPermissionResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingPermissionResult = null
        }
    }

    /// Absolute path of the shared "Download" directory (usually /storage/emulated/0/Download).
    @Suppress("DEPRECATION")
    private fun getDownloadsDirectory(): String {
        return Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath
    }

    private fun isAnimationsEnabled() : Boolean {
        return Settings.Global.getFloat(this.getContentResolver(),
            Settings.Global.ANIMATOR_DURATION_SCALE, 1.0f) != 0.0f;
    }

    private fun handleGetFileDescriptor(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("INVALID_ARGUMENT", "Missing content URI", null)
            return
        }

        val uri = Uri.parse(uriString)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("INVALID_ARGUMENT", "Expected a content:// URI", null)
            return
        }

        try {
            val parcelFileDescriptor = contentResolver.openFileDescriptor(uri, "r")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            // Ownership of the detached descriptor is transferred to the caller. It must be
            // closed by Rust (or whichever native consumer receives it) after use.
            parcelFileDescriptor.use {
                result.success(it.detachFd())
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message ?: "Failed to open content URI", null)
        }
    }

    /// Creates a new file inside a SAF directory and opens it for writing.
    ///
    /// Returns the URI of the created document (Android may rename the file on
    /// collisions) and an owned writable file descriptor. The descriptor must be
    /// closed by the native consumer it is passed to.
    private fun handleCreateFile(call: MethodCall, result: MethodChannel.Result) {
        val parentUriString = call.argument<String>("parentUri")
        val fileName = call.argument<String>("fileName")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        if (parentUriString == null || fileName == null) {
            result.error("INVALID_ARGUMENT", "Missing parentUri or fileName", null)
            return
        }

        runSaf(result) {
            val parentUri = Uri.parse(parentUriString)
            val segments = parentUri.pathSegments
            val parentDocumentUri = if (segments.size == 2 && segments[0] == "tree") {
                DocumentsContract.buildDocumentUriUsingTree(parentUri, DocumentsContract.getTreeDocumentId(parentUri))
            } else parentUri
            val documentUri = DocumentsContract.createDocument(contentResolver, parentDocumentUri, mimeType, fileName)
                ?: throw SafDirectoryResolver.Failure("CREATE_FAILED", "The provider did not create a document")
            // The legacy target remains separate from the inactive transaction API.
            // No cleanup guesses ownership when the provider returns or opens an unexpected document.
            val descriptor = contentResolver.openFileDescriptor(documentUri, "wt")
                ?: throw SafDirectoryResolver.Failure("OPEN_FAILED", "The provider did not return a writable descriptor")
            SafOpenedDocument(descriptor, documentUri.toString())
        }
    }

    /// Whole-file retry keeps the original provider-returned URI; worker owns the FD until UI handoff.
    private fun handleOpenFileForWriting(call: MethodCall, result: MethodChannel.Result) {
        val value = call.argument<String>("uri")
        if (value == null || Uri.parse(value).scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("INVALID_ARGUMENT", "Expected a content:// URI", null)
            return
        }
        runSaf(result) {
            val descriptor = contentResolver.openFileDescriptor(Uri.parse(value), "wt")
                ?: throw SafDirectoryResolver.Failure("OPEN_FAILED", "The provider did not return a writable descriptor")
            SafOpenedDocument(descriptor)
        }
    }

    private fun openDirectoryPicker(onlyPath: Boolean) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        if (onlyPath && pendingDirectoryWritable) intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        launchPicker(
            intent,
            if (onlyPath) REQUEST_CODE_PICK_DIRECTORY_PATH else REQUEST_CODE_PICK_DIRECTORY
        )
    }

    private fun openFilePicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            putExtra("multi-pick", true)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        launchPicker(intent, REQUEST_CODE_PICK_FILE)
    }

    private fun launchPicker(intent: Intent, requestCode: Int) {
        try {
            startActivityForResult(intent, requestCode)
        } catch (_: Exception) {
            val reply = pendingResult
            pendingResult = null
            reply?.error("unavailable", "The system document picker is unavailable", null)
        }
    }

    @SuppressLint("WrongConstant")
    @Override
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode !in listOf(REQUEST_CODE_PICK_DIRECTORY, REQUEST_CODE_PICK_DIRECTORY_PATH, REQUEST_CODE_PICK_FILE)) return
        if (resultCode == Activity.RESULT_CANCELED) {
            pendingResult?.success(null)
            pendingResult = null
            return
        }

        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingResult?.error("Error $resultCode", "Failed to access directory or file", null)
            pendingResult = null
            return
        }

        when (requestCode) {
            REQUEST_CODE_PICK_DIRECTORY -> {
                val uri: Uri? = data.data
                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    val reply = pendingResult
                    pendingResult = null
                    if (reply != null) {
                        try {
                            if (takeFlags and Intent.FLAG_GRANT_READ_URI_PERMISSION == 0) throw SecurityException()
                            contentResolver.takePersistableUriPermission(uri, takeFlags)
                            folderSelection.read(uri, reply)
                        } catch (_: SecurityException) {
                            reply.error("permission", "permission", null)
                        } catch (_: Exception) {
                            reply.error("unavailable", "unavailable", null)
                        }
                    }
                } else {
                    pendingResult?.error("Error", "Failed to access directory", null)
                    pendingResult = null
                }
            }

            REQUEST_CODE_PICK_DIRECTORY_PATH -> {
                val reply = pendingResult ?: return
                pendingResult = null
                val uri = data.data
                val writable = pendingDirectoryWritable
                val required = Intent.FLAG_GRANT_READ_URI_PERMISSION or (if (writable) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
                val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri == null || flags and required != required
                    || data.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION == 0) {
                    reply.error("PERMISSION_DENIED", "Select a writable directory with persistent access", null)
                    return
                }
                runSaf(reply) {
                    contentResolver.takePersistableUriPermission(uri, flags)
                    if (writable) AndroidSafDirectory(contentResolver).resolve(uri.toString(), emptyList())
                    uri.toString()
                }
            }

            REQUEST_CODE_PICK_FILE -> {
                // Detach exactly once before parsing or calling a provider. Every
                // failure leaves the picker available for a subsequent retry.
                val reply = pendingResult ?: return
                pendingResult = null
                try {
                    val clip = data.clipData
                    val count = clip?.itemCount ?: if (data.data != null) 1 else 0
                    if (count == 0 || count > SafFileSelection.MAX_FILES) {
                        reply.error(if (count == 0) "invalid" else "limit", "Invalid file selection size", null)
                        return
                    }
                    val uris = if (clip != null) (0 until count).map { clip.getItemAt(it).uri?.toString() }
                        else listOf(data.data?.toString())
                    if (uris.any { it == null }) {
                        reply.error("invalid", "A selected item has no document URI", null)
                        return
                    }
                    fileSelection.read(uris.filterNotNull(), data.flags, reply)
                } catch (_: Exception) {
                    reply.error("unavailable", "The selected documents are unavailable", null)
                }
            }
        }
    }

    private fun openGallery() {
        val intent = Intent()
        intent.action = Intent.ACTION_VIEW
        intent.type = "image/*"
        startActivity(intent)
    }
}
