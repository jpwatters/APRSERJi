import Foundation

/** A KISS TNC advertised on the local network over DNS-SD (Dire Wolf advertises _kiss-tnc._tcp). */
struct DiscoveredTnc: Hashable {
    let name: String
    let host: String
    let port: Int
}

/** Browses the local network for KISS TNCs for about ten seconds. */
final class TncDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var found: [DiscoveredTnc] = []
    @Published private(set) var searching = false
    private var browser: NetServiceBrowser?
    private var pending: [NetService] = []

    func search() {
        browser?.stop()
        found = []
        pending = []
        searching = true
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: "_kiss-tnc._tcp.", inDomain: "local.")
        browser = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.browser?.stop()
            self?.searching = false
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        pending.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        let entry = DiscoveredTnc(name: sender.name, host: host.hasSuffix(".") ? String(host.dropLast()) : host, port: sender.port)
        if !found.contains(entry) { found.append(entry) }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) { searching = false }
}
