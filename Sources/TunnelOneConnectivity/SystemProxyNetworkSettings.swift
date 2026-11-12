// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NetworkExtension
#if SWIFT_PACKAGE
import TunnelOnePolicy
#endif

enum SystemProxyNetworkSettings {
    static func make(_ snapshot: SystemProxySnapshot) -> NEProxySettings? {
        guard snapshot.hasProxy else { return nil }
        let settings = NEProxySettings()
        settings.httpEnabled = snapshot.http != nil
        settings.httpsEnabled = snapshot.https != nil
        if let endpoint = snapshot.http { settings.httpServer = NEProxyServer(address: endpoint.host, port: endpoint.port) }
        if let endpoint = snapshot.https { settings.httpsServer = NEProxyServer(address: endpoint.host, port: endpoint.port) }
        settings.autoProxyConfigurationEnabled = snapshot.pacURL != nil || snapshot.pacScript != nil
        settings.proxyAutoConfigurationURL = snapshot.pacURL
        settings.proxyAutoConfigurationJavaScript = snapshot.pacScript
        settings.exceptionList = snapshot.exceptions
        settings.excludeSimpleHostnames = snapshot.excludeSimpleHostnames
        settings.matchDomains = [""]
        // NEProxySettings has no SOCKS field. Its original, correctly typed
        // dictionary is synchronized to this tunnel's temporary State service.
        return settings
    }
}
