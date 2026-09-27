package org.localsend.localsend_app

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build

/** Read-only signals, not a claim about a particular socket's route. */
object NetworkSignalReader {
    fun read(context: Context): Map<String, Any> {
        return try {
            val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val vpn = manager.allNetworks.any { network ->
                manager.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
            }
            val proxyKnown = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
            val proxy = if (proxyKnown) manager.defaultProxy != null else false
            mapOf("vpnKnown" to true, "vpnDetected" to vpn, "proxyKnown" to proxyKnown, "proxyEnabled" to proxy, "networkRoutes" to NetworkRouteReader.snapshot(context))
        } catch (_: SecurityException) {
            mapOf("vpnKnown" to false, "proxyKnown" to false, "networkRoutes" to NetworkRouteReader.snapshot(context))
        }
    }
}
