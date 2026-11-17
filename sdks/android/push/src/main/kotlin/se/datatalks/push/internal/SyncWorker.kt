package se.datatalks.push.internal

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Runs [PushSync] when a network is available, also after process death. Retries are scheduled here rather than with
 * `Result.retry()`: WorkManager's backoff grows to 5 hours (the spec caps it at 1) and ignores `Retry-After`.
 */
internal class SyncWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    override fun doWork(): Result {
        val runtime = PushRuntime.get(applicationContext)
        when (val outcome = runtime.sync.run()) {
            SyncOutcome.Done -> runtime.store.failedAttempts = 0
            is SyncOutcome.RetryAfter -> SyncScheduler.after(applicationContext, outcome.seconds)
            SyncOutcome.Backoff -> {
                val attempt = runtime.store.failedAttempts
                runtime.store.failedAttempts = attempt + 1
                SyncScheduler.after(applicationContext, PushSync.backoffSeconds(attempt))
            }
        }

        return Result.success()
    }
}

internal object SyncScheduler {
    private const val TAG = "DataTalksPush"
    private const val WORK_NAME = "se.datatalks.push.sync"

    /** Something changed: run now, replacing any scheduled retry. A `Retry-After` still applies ([PushStore.notBefore]). */
    fun now(context: Context) = enqueue(context, ExistingWorkPolicy.REPLACE, 0)

    /** Nothing urgent: a scheduled retry keeps its time. */
    fun whenIdle(context: Context) = enqueue(context, ExistingWorkPolicy.KEEP, 0)

    fun after(context: Context, seconds: Long) = enqueue(context, ExistingWorkPolicy.REPLACE, seconds)

    private fun enqueue(context: Context, policy: ExistingWorkPolicy, delaySeconds: Long) {
        val request = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setInitialDelay(delaySeconds, TimeUnit.SECONDS)
            .build()
        try {
            WorkManager.getInstance(context).enqueueUniqueWork(WORK_NAME, policy, request)
        } catch (e: IllegalStateException) {
            Log.e(TAG, "WorkManager isn't available, so the SDK can't reach the service: ${e.message}")
        }
    }
}
