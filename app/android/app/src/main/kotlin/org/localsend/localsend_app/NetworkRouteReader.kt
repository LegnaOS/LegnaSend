package org.localsend.localsend_app

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import java.util.UUID

/** Process-local Network identities only; never binds the process or any socket. */
object NetworkRouteReader {
    private val epoch = UUID.randomUUID().toString()
    private var revision = 0L
    private var manager: ConnectivityManager? = null
    private var registered = false
    private data class Lease(val signature: String, val id: String)
    private val leases = mutableMapOf<String, Lease>()
    private val lostHandles = linkedSetOf<String>()
    private var listener: ((Map<String, Any>) -> Unit)? = null
    private var listenerId = 0L

    @Synchronized private fun start(context: Context) {
        if (Build.VERSION.SDK_INT < 23 || registered) return
        val service = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                synchronized(this@NetworkRouteReader) { lostHandles.remove(java.lang.Long.toUnsignedString(network.networkHandle)) }
                changed()
            }
            override fun onLost(network: Network) {
                synchronized(this@NetworkRouteReader) {
                    val handle = java.lang.Long.toUnsignedString(network.networkHandle)
                    leases.remove(handle)
                    lostHandles.add(handle)
                    while (lostHandles.size > 128) lostHandles.remove(lostHandles.first())
                }
                changed()
            }
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = changed()
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = changed()
        }
        service.registerNetworkCallback(NetworkRequest.Builder().clearCapabilities().removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), callback)
        manager = service
        registered = true
    }

    private fun changed() {
        val callback = synchronized(this) { listener }
        callback?.invoke(snapshot(null))
    }

    @Synchronized fun observe(context: Context, callback: (Map<String, Any>) -> Unit): Long {
        try { start(context) } catch (_: Exception) { }
        listenerId++
        listener = callback
        return listenerId
    }

    @Synchronized fun stopObserving(id: Long?) {
        if (id != null && id == listenerId) listener = null
    }

    @Synchronized fun snapshot(context: Context?): Map<String, Any> {
        revision++
        val result = mutableListOf<Map<String, Any>>()
        val active = mutableSetOf<String>()
        try {
            if (context != null) start(context)
            if (Build.VERSION.SDK_INT >= 23 && registered) {
                val service = manager!!
                for (network in service.allNetworks.sortedBy { it.networkHandle }.take(64)) {
                    val properties = service.getLinkProperties(network) ?: continue
                    val capabilities = service.getNetworkCapabilities(network) ?: continue
                    val name = properties.interfaceName ?: continue
                    val addresses = properties.linkAddresses.map { it.address.hostAddress?.substringBefore('%') }.filterNotNull().distinct().sorted().take(64)
                    if (addresses.isEmpty() || name.isEmpty() || name.length > 256) continue
                    val handle = java.lang.Long.toUnsignedString(network.networkHandle)
                    if (handle == "0" || lostHandles.contains(handle)) continue
                    val vpn = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                    val wifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                    val cellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
                    val signature = "$name|${addresses.joinToString(",")}|$vpn|$wifi|$cellular"
                    val lease = leases[handle]?.takeIf { it.signature == signature } ?: Lease(signature, UUID.randomUUID().toString())
                    leases[handle] = lease
                    active.add(handle)
                    result.add(mapOf("handle" to handle, "lease" to lease.id, "interfaceName" to name, "addresses" to addresses,
                        "vpn" to vpn, "wifi" to wifi, "cellular" to cellular))
                }
            }
        } catch (_: Exception) { result.clear(); active.clear() }
        leases.keys.retainAll(active)
        return mapOf("epoch" to epoch, "revision" to revision, "networks" to result)
    }
}
