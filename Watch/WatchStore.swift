import Foundation
import WatchConnectivity

/** The Watch end of the link to APRSERJi on the iPhone: holds the latest snapshot and sends commands back. */
@MainActor
final class WatchStore: NSObject, ObservableObject {
    @Published private(set) var snapshot: WatchSnapshot?
    @Published private(set) var phoneReachable = false
    /** A short note after a command, e.g. "Beacon requested". */
    @Published var note: String?

    private let session: WCSession? = WCSession.isSupported() ? .default : nil

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func send(_ command: WatchCommand, note: String? = nil) {
        guard let session else { return }
        if session.activationState == .activated && session.isReachable {
            session.sendMessage(command.dictionary, replyHandler: nil) { [weak self] _ in
                // Not delivered right away; queue it so the iPhone gets it later.
                session.transferUserInfo(command.dictionary)
                Task { @MainActor in self?.note = "Will send when your iPhone is in reach" }
            }
        } else {
            session.transferUserInfo(command.dictionary)
        }
        if let note { self.note = note }
    }

    func refresh() { send(.refresh) }

    fileprivate func apply(_ context: [String: Any]) {
        if let value = WatchSnapshot(context) { snapshot = value }
    }

    fileprivate func setReachable(_ reachable: Bool) { phoneReachable = reachable }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.apply(context)
            self.setReachable(reachable)
            self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.setReachable(reachable) }
    }
}
