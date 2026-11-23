// WHO-IS callsign lookup. The FCC sources and parsing are ported from KC9KKO's Club Members app
// (ClubMembership/Lookup/FCCLookup.swift).
import Foundation
import SwiftUI

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/** What a license lookup returns, already tidied for display. */
struct LicenseInfo: Equatable, Sendable, Identifiable {
    var id: String { callSign }
    var callSign = ""
    var name = ""
    var street = ""
    var city = ""
    var state = ""
    var zip = ""
    var licenseClass = ""
    var expires = ""
    var source = ""
    /// License status as the source gives it (HamDB and the FCC file: "A", "E", "C", "T"); "" if not given.
    var status = ""
    var latitude: Double?
    var longitude: Double?
}

/**
 * Looks up a US amateur callsign in FCC ULS license data:
 * 1. callook.info — mirror of the FCC ULS amateur database (updated daily).
 * 2. HamDB (api.hamdb.org) — second FCC ULS mirror, used if callook.info doesn't answer.
 * 3. The FCC license database downloaded on this device (Setup ▸ Callsign lookup), if installed.
 */
enum FCCLookup {
    enum LookupError: LocalizedError {
        case notFound(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case let .notFound(cs): return "\(cs) isn't in the FCC amateur license database. It may be a non-US callsign, a tactical call or an object."
            case let .unavailable(msg): return "Callsign lookup unavailable: \(msg)"
            }
        }
    }

    static func lookup(_ rawCallSign: String) async throws -> LicenseInfo {
        let cs = baseCallSign(rawCallSign)
        guard !cs.isEmpty else { throw LookupError.notFound(rawCallSign) }
        do {
            return try await callook(cs)
        } catch {
            do {
                return try await hamdb(cs)
            } catch {
                if let local = FCCDatabase.license(cs) { return local.info }
                throw error
            }
        }
    }

    /// "KC9KKO-9" or "VE3/W9ABC/M" -> the part that is the licensed callsign.
    static func baseCallSign(_ s: String) -> String {
        let noSSID = s.uppercased().split(separator: "-").first.map(String.init) ?? ""
        let parts = noSSID.filter { $0.isLetter || $0.isNumber || $0 == "/" }.split(separator: "/").map(String.init)
        return parts.max(by: { $0.count < $1.count }) ?? ""
    }

    // MARK: Sources

    private static func callook(_ cs: String) async throws -> LicenseInfo {
        let json = try await fetchJSON("https://callook.info/\(cs)/json")
        guard (json["status"] as? String)?.uppercased() == "VALID" else { throw LookupError.notFound(cs) }
        let address = json["address"] as? [String: Any] ?? [:]
        let current = json["current"] as? [String: Any] ?? [:]
        let other = json["otherInfo"] as? [String: Any] ?? [:]
        let location = json["location"] as? [String: Any] ?? [:]
        let (city, state, zip) = splitCityLine(address["line2"] as? String ?? "")
        var info = LicenseInfo()
        info.callSign = (current["callsign"] as? String ?? cs).uppercased()
        info.name = Tidy.words(json["name"] as? String ?? "")
        info.street = Tidy.words(address["line1"] as? String ?? "")
        info.city = Tidy.words(city)
        info.state = state
        info.zip = zip
        info.licenseClass = Tidy.words(current["operClass"] as? String ?? "")
        info.expires = other["expiryDate"] as? String ?? ""
        info.status = "A"
        info.source = "FCC ULS via callook.info"
        info.latitude = number(location["latitude"])
        info.longitude = number(location["longitude"])
        return info
    }

    private static func hamdb(_ cs: String) async throws -> LicenseInfo {
        let json = try await fetchJSON("https://api.hamdb.org/v1/\(cs)/json/APRSERJi")
        let root = json["hamdb"] as? [String: Any] ?? [:]
        let messages = root["messages"] as? [String: Any] ?? [:]
        let c = root["callsign"] as? [String: Any] ?? [:]
        func s(_ k: String) -> String {
            let v = (c[k] as? String ?? "").trimmed
            return v.uppercased() == "NOT_FOUND" ? "" : v
        }
        guard (messages["status"] as? String)?.uppercased() == "OK", !s("call").isEmpty else {
            throw LookupError.notFound(cs)
        }
        var info = LicenseInfo()
        info.callSign = s("call").uppercased()
        info.name = Tidy.words([s("fname"), s("mi"), s("name"), s("suffix")].filter { !$0.isEmpty }.joined(separator: " "))
        info.street = Tidy.words(s("addr1"))
        info.city = Tidy.words(s("addr2"))
        info.state = s("state").uppercased()
        info.zip = s("zip")
        info.licenseClass = licenseClassName(s("class"))
        info.expires = s("expires")
        info.status = s("status")
        info.source = "FCC ULS via HamDB"
        info.latitude = number(c["lat"])
        info.longitude = number(c["lon"])
        return info
    }

    private static func fetchJSON(_ urlString: String) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw LookupError.unavailable("bad address") }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("APRSERJi/1.0 (KC9KKO)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw LookupError.unavailable("server returned \(http.statusCode)")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LookupError.unavailable("unexpected reply")
            }
            return obj
        } catch let e as LookupError {
            throw e
        } catch {
            throw LookupError.unavailable(error.localizedDescription)
        }
    }

    /// "MORRIS, IL 60450" -> ("MORRIS", "IL", "60450")
    static func splitCityLine(_ line: String) -> (String, String, String) {
        let parts = line.split(separator: ",", maxSplits: 1).map { String($0).trimmed }
        guard parts.count == 2 else { return (line.trimmed, "", "") }
        let rest = parts[1].split(separator: " ").map(String.init)
        return (parts[0], rest.first?.uppercased() ?? "", rest.count > 1 ? rest[1] : "")
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmed) }
        return nil
    }

    static func licenseClassName(_ code: String) -> String {
        switch code.uppercased() {
        case "T": return "Technician"
        case "G": return "General"
        case "E": return "Amateur Extra"
        case "A": return "Advanced"
        case "N": return "Novice"
        default: return Tidy.words(code)
        }
    }
}

/// FCC data is all capitals; make it read naturally.
enum Tidy {
    private static let keepUpper: Set<String> = ["PO", "NE", "NW", "SE", "SW", "N", "S", "E", "W", "II", "III", "IV", "RR", "US"]

    /// "123 N MAIN ST APT 2B" -> "123 N Main St Apt 2B"
    static func words(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).map { w -> String in
            let word = String(w)
            if word.contains(where: \.isNumber) { return word.uppercased() }
            let bare = word.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            if keepUpper.contains(bare) { return word.uppercased() }
            if word.hasPrefix("MC"), word.count > 2 {
                return "Mc" + word.dropFirst(2).prefix(1).uppercased() + word.dropFirst(3).lowercased()
            }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

/** The WHO-IS sheet: license holder, location, class and expiration for a station's callsign. */
struct WhoIsView: View {
    let callsign: String
    @Environment(\.dismiss) private var dismiss
    @State private var info: LicenseInfo?
    @State private var problem: String?

    private var base: String { FCCLookup.baseCallSign(callsign) }

    var body: some View {
        NavigationStack {
            Form {
                if let info {
                    Section {
                        LabeledContent("Callsign", value: info.callSign)
                        LabeledContent("Name", value: info.name)
                        if !info.licenseClass.isEmpty { LabeledContent("License class", value: info.licenseClass) }
                        if !info.expires.isEmpty { LabeledContent("Expires", value: info.expires) }
                        if !info.status.isEmpty { LabeledContent("Status", value: statusName(info.status)) }
                    }
                    Section("Mailing address") {
                        if !info.street.isEmpty { Text(info.street) }
                        Text([info.city, [info.state, info.zip].filter { !$0.isEmpty }.joined(separator: " ")]
                            .filter { !$0.isEmpty }.joined(separator: ", "))
                    }
                    Section {
                        Text("Source: \(info.source)").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let problem {
                    Section {
                        Label(problem, systemImage: "questionmark.circle")
                    }
                } else {
                    Section { ProgressView("Looking up \(base)…") }
                }
                Section {
                    Link("Open \(base) on QRZ.com", destination: URL(string: "https://www.qrz.com/db/\(base)")!)
                    Link("Open \(callsign) on aprs.fi", destination: URL(string: "https://aprs.fi/info/a/\(callsign)")!)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("WHO-IS \(base)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
        .task(id: callsign) {
            info = nil
            problem = nil
            do {
                info = try await FCCLookup.lookup(callsign)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func statusName(_ code: String) -> String {
        switch code.uppercased() {
        case "A": return "Active"
        case "E": return "Expired (grace period)"
        case "C": return "Cancelled"
        case "T": return "Terminated"
        default: return code
        }
    }
}
