import AprsCore
import SwiftUI

/**
 * Bulletins tab: NWS alerts for your location and the map, APRS bulletins (BLN…, NWS-…) heard in range, and
 * ANSRVR announcement groups — join or leave a group, send a CQ to it, and read what members announce.
 */
struct BulletinsView: View {
    let core: AppleAprs
    let account: String
    let bulletins: [AprsBulletin]
    let revision: Int64
    @ObservedObject var warnings: NWSWarnings
    @AppStorage("nwsEnabled") private var nwsEnabled = true
    @AppStorage("ansrvrGroups") private var savedGroups = ""
    @State private var group = ""
    @State private var cqText = ""
    @State private var problem: String?
    @State private var announcements: [ChatRow] = []

    private var groups: [String] { savedGroups.split(separator: ",").map(String.init).filter { !$0.isEmpty } }

    var body: some View {
        NavigationStack {
            Form {
                nwsSection
                bulletinSection
                announcementSection
            }
            .formStyle(.grouped)
            .navigationTitle("Bulletins")
        }
        .task(id: "\(account)|\(revision)") {
            guard AprsProtocol.shared.validCallsign(value: account) else { return }
            let rows = (try? await core.messages(account: account, peer: "ANSRVR")) ?? []
            announcements = rows.reversed()
        }
    }

    @ViewBuilder private var nwsSection: some View {
        Section {
            Toggle("Show NWS warnings", isOn: $nwsEnabled)
            if nwsEnabled {
                if warnings.atLocation.isEmpty {
                    Text("No active alerts for your location.").foregroundStyle(.secondary)
                }
                ForEach(warnings.atLocation) { alert in AlertRow(alert: alert) }
                if !warnings.mapped.isEmpty {
                    DisclosureGroup("\(warnings.mapped.count) warning areas on the map") {
                        ForEach(warnings.mapped) { alert in AlertRow(alert: alert) }
                    }
                }
                if let updated = warnings.updated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened)) from api.weather.gov")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let problem = warnings.problem {
                    Text("Couldn't reach the National Weather Service: \(problem)").font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("NWS warnings")
        } footer: {
            Text("United States only. Storm-based warnings (tornado, severe thunderstorm, flash flood) are drawn on the map; county- and zone-wide alerts are listed for your location.")
        }
    }

    @ViewBuilder private var bulletinSection: some View {
        Section("APRS bulletins") {
            if bulletins.isEmpty {
                Text("No bulletins heard yet. Bulletins sent within your receive range appear here.").foregroundStyle(.secondary)
            }
            ForEach(bulletins, id: \.self) { bulletin in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(bulletin.destination).font(.caption.bold().monospaced())
                        Text("from \(bulletin.sender)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Date(timeIntervalSince1970: Double(bulletin.time) / 1000).formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(bulletin.text).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private var announcementSection: some View {
        Section {
            ForEach(groups, id: \.self) { name in
                HStack {
                    Text(name).font(.body.monospaced())
                    Spacer()
                    Button("Leave") { send("U", name, "", remember: false, forget: name) }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Group name, e.g. CQ or ILLINOIS", text: $group)
                Button("Join") { send("J", group, "", remember: true) }
                    .disabled(group.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !groups.isEmpty {
                Picker("Announce to", selection: $group) {
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    TextField("Announcement", text: $cqText)
                    Button("Send") { send("CQ", group, cqText, remember: false) }
                        .disabled(cqText.trimmingCharacters(in: .whitespaces).isEmpty || !groups.contains(group))
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            ForEach(announcements.prefix(30), id: \.id) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.outgoing ? "You → ANSRVR" : "ANSRVR").font(.caption.bold())
                    Text(row.body)
                }
            }
        } header: {
            Text("Announcements (ANSRVR)")
        } footer: {
            Text("ANSRVR relays announcements to every station that joined a group. Commands go through the Messages outbox, so sending needs a verified login (Enable sending + passcode). Groups expire after 12 hours without activity; join again to stay in.")
        }
    }

    private func send(_ action: String, _ name: String, _ text: String, remember: Bool, forget: String? = nil) {
        let groupName = name.trimmingCharacters(in: .whitespaces).uppercased()
        guard AprsProtocol.shared.validCallsign(value: account) else {
            problem = "Enter your callsign first."
            return
        }
        problem = nil
        Task {
            do {
                let ok = try await core.announcement(account: account, action: action, group: groupName, text: text).boolValue
                if !ok {
                    problem = "Use 1–20 letters, digits, - or _ for the group, and printable text without { | ~."
                    return
                }
                var list = groups
                if remember, !list.contains(groupName) { list.append(groupName) }
                if let forget { list.removeAll { $0 == forget } }
                savedGroups = list.joined(separator: ",")
                if action == "CQ" { cqText = "" }
                if action == "J" { group = groupName }
            } catch {
                problem = "Unable to queue the ANSRVR command."
            }
        }
    }
}

private struct AlertRow: View {
    let alert: NWSAlert
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle().fill(alert.color).frame(width: 9, height: 9)
                Text(alert.event).font(.headline)
                Spacer()
                if let expires = alert.expires {
                    Text("until \(expires.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !alert.headline.isEmpty { Text(alert.headline).font(.callout) }
            Text(alert.area).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
    }
}
