package com.zarz.mornye

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject

internal fun DownloadService.configureNativeWorkerNetworkPolicy(settingsJson: String) {
    nativeWorkerDownloadNetworkMode = try {
        JSONObject(settingsJson).optString("download_network_mode", "any")
    } catch (_: Exception) {
        "any"
    }

    unregisterNativeWorkerNetworkCallback()
    if (!NativeWorkerPolicy.requiresWifi(nativeWorkerDownloadNetworkMode)) {
        nativeWorkerNetworkPaused = false
        return
    }

    nativeWorkerNetworkPaused = !hasUsableWifiConnection()
    val connectivityManager =
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            synchronized(nativeWorkerWifiNetworks) {
                nativeWorkerWifiNetworks.add(network)
            }
            refreshNativeWorkerNetworkPause()
        }

        override fun onLost(network: Network) {
            synchronized(nativeWorkerWifiNetworks) {
                nativeWorkerWifiNetworks.remove(network)
            }
            refreshNativeWorkerNetworkPause()
        }

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) {
            synchronized(nativeWorkerWifiNetworks) {
                if (networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                    networkCapabilities.hasCapability(
                        NetworkCapabilities.NET_CAPABILITY_INTERNET,
                    )
                ) {
                    nativeWorkerWifiNetworks.add(network)
                } else {
                    nativeWorkerWifiNetworks.remove(network)
                }
            }
            refreshNativeWorkerNetworkPause()
        }
    }
    try {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivityManager.registerNetworkCallback(request, callback)
        nativeWorkerNetworkCallback = callback
    } catch (e: Exception) {
        android.util.Log.w(
            "DownloadService",
            "Failed to monitor Wi-Fi for native worker: ${e.message}",
        )
        // Callback registration can fail when the process/system callback quota is
        // exhausted. Keep the Wi-Fi-only queue observable instead of leaving it
        // paused forever with no event capable of resuming it.
        nativeWorkerNetworkFallbackJob?.cancel()
        nativeWorkerNetworkFallbackJob = serviceScope.launch {
            while (NativeWorkerPolicy.requiresWifi(nativeWorkerDownloadNetworkMode)) {
                delay(5_000)
                refreshNativeWorkerNetworkPause()
                // The progress coordinator sleeps while the queue waits, so
                // this poll renews the wake lock it depends on.
                refreshNativeWorkerWakeLock()
                if (nativeWorkerJob?.isActive != true) break
            }
        }
    }
}

internal fun DownloadService.hasUsableWifiConnection(): Boolean {
    val connectivityManager =
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    if (synchronized(nativeWorkerWifiNetworks) {
            nativeWorkerWifiNetworks.isNotEmpty()
        }
    ) {
        return true
    }
    return try {
        val activeNetwork = connectivityManager.activeNetwork ?: return false
        val capabilities =
            connectivityManager.getNetworkCapabilities(activeNetwork) ?: return false
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    } catch (_: Exception) {
        false
    }
}

internal fun DownloadService.refreshNativeWorkerNetworkPause() {
    if (!NativeWorkerPolicy.requiresWifi(nativeWorkerDownloadNetworkMode)) return

    val shouldPause = NativeWorkerPolicy.shouldPauseForNetwork(
        nativeWorkerDownloadNetworkMode,
        hasUsableWifiConnection(),
    )
    if (shouldPause == nativeWorkerNetworkPaused) return

    nativeWorkerNetworkPaused = shouldPause
    onNativeWorkerStateChanged()
    if (nativeWorkerJob?.isActive != true) return

    if (shouldPause) {
        currentStatus = if (nativeWorkerVerificationPaused) {
            "verification_required"
        } else {
            "waiting_wifi"
        }
        cancelActiveNativeItemForPause()
        updateNotification(0L, 0L)
    } else {
        if (NativeWorkerPolicy.shouldHoldWifiReturnGrace(
                userPaused = isNativeWorkerUserPaused(),
                verificationPaused = nativeWorkerVerificationPaused,
            )
        ) {
            holdWifiReturnGraceWakeLock()
        }
        currentStatus = if (nativeWorkerVerificationPaused) {
            "verification_required"
        } else {
            "preparing"
        }
        updateNotification(0L, 0L)
    }
    writeNativeWorkerSnapshotAsync(
        isRunning = nativeWorkerJob?.isActive == true,
        isPaused = isNativeWorkerPaused(),
        currentItemId = "",
        message = if (isNativeWorkerPaused()) {
            nativeWorkerPauseMessage()
        } else {
            "Wi-Fi restored"
        },
        includeItems = true,
    )
}

internal fun DownloadService.unregisterNativeWorkerNetworkCallback() {
    nativeWorkerNetworkFallbackJob?.cancel()
    nativeWorkerNetworkFallbackJob = null
    val callback = nativeWorkerNetworkCallback
    nativeWorkerNetworkCallback = null
    synchronized(nativeWorkerWifiNetworks) {
        nativeWorkerWifiNetworks.clear()
    }
    if (callback == null) return
    try {
        val connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        connectivityManager.unregisterNetworkCallback(callback)
    } catch (_: Exception) {
    }
}
