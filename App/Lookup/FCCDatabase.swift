// Ported from KC9KKO's Club Members app (ClubMembership/Lookup/FCCDatabase.swift).
import Foundation
import SQLite3
import Compression
import SwiftUI

/// The FCC's complete amateur license database (ULS public access file `l_amat.zip`), downloaded once and
/// kept on this device as a small SQLite file, so APRSERJi's WHO-IS lookup can answer without asking any website.
///
/// The zip holds pipe-delimited files joined by Unique System Identifier (field 2):
///   HD.dat  5 call sign, 6 license status (A active, E expired, C cancelled, T terminated), 9 expired date
///   EN.dat  5 call sign, 6 entity type (L = licensee), 8 entity name, 9 first, 10 MI, 11 last, 12 suffix,
///           16 street, 17 city, 18 state, 19 ZIP, 20 PO box
///   AM.dat  5 call sign, 6 operator class
/// Only active and expired (grace period) licenses are kept.
enum FCCDatabase {
    static let downloadURL = URL(string: "https://data.fcc.gov/download/pub/uls/complete/l_amat.zip")!

    enum DBError: LocalizedError {
        case download(String), unzip(String), sqlite(String), cancelled
        var errorDescription: String? {
            switch self {
            case let .download(m): return "Couldn't download the FCC database: \(m)"
            case let .unzip(m): return "Couldn't read the FCC download: \(m)"
            case let .sqlite(m): return "Couldn't build the license database: \(m)"
            case .cancelled: return "Stopped."
            }
        }
    }

    // MARK: Where it lives

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("APRSERJi/FCC", isDirectory: true)
    }
    static var databaseURL: URL { folder.appendingPathComponent("fcc-amateur.sqlite") }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: databaseURL.path) }

    struct Info: Sendable {
        var licenses: Int
        var builtAt: Date
        var bytes: Int64
    }

    static func info() -> Info? {
        guard isInstalled, let db = try? open(readOnly: true) else { return nil }
        defer { sqlite3_close(db) }
        let count = Int((try? scalar(db, "SELECT value FROM meta WHERE key = 'count'")) ?? "0") ?? 0
        let built = Double((try? scalar(db, "SELECT value FROM meta WHERE key = 'builtAt'")) ?? "0") ?? 0
        let attrs = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return Info(licenses: count, builtAt: Date(timeIntervalSince1970: built), bytes: size)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: databaseURL)
    }

    // MARK: Download and build

    enum Step: Sendable {
        case downloading(done: Int64, total: Int64)
        case reading(String)
        case indexing
    }

    /// Downloads l_amat.zip and builds the database. `progress` is called from background threads.
    static func downloadAndBuild(progress: @escaping @Sendable (Step) -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("l_amat.zip")
        let downloader = FileDownloader(destination: zip) { done, total in progress(.downloading(done: done, total: total)) }
        try await withTaskCancellationHandler {
            _ = try await downloader.run(downloadURL)
        } onCancel: {
            downloader.cancel()
        }
        defer { try? FileManager.default.removeItem(at: zip) }
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            try build(from: zip, progress: progress)
        }.value
    }

    private static func build(from zipURL: URL, progress: @escaping @Sendable (Step) -> Void) throws {
        let tmp = folder.appendingPathComponent("fcc-amateur-new.sqlite")
        try? FileManager.default.removeItem(at: tmp)
        var db: OpaquePointer?
        guard sqlite3_open(tmp.path, &db) == SQLITE_OK, let db else { throw DBError.sqlite("can't create the file") }
        var closed = false
        defer { if !closed { sqlite3_close(db) }; try? FileManager.default.removeItem(at: tmp) }

        try exec(db, """
            PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;
            CREATE TABLE hd(usi INTEGER PRIMARY KEY, call TEXT, status TEXT, expires TEXT);
            CREATE TABLE am(usi INTEGER PRIMARY KEY, class TEXT);
            CREATE TABLE en(usi INTEGER PRIMARY KEY, name TEXT, first TEXT, mi TEXT, last TEXT, suffix TEXT,
                            street TEXT, city TEXT, state TEXT, zip TEXT, pobox TEXT);
            """)

        let zip = try StreamingZip(url: zipURL)
        func load(_ file: String, _ sql: String, _ bind: @escaping (OpaquePointer, [Substring]) -> Bool) throws {
            progress(.reading(file))
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw DBError.sqlite(lastError(db)) }
            defer { sqlite3_finalize(stmt) }
            try exec(db, "BEGIN")
            var n = 0
            try zip.forEachLine(of: file) { line in
                let f = line.split(separator: "|", omittingEmptySubsequences: false)
                guard bind(stmt, f) else { return }
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
                n += 1
                if n % 50_000 == 0 && Task.isCancelled { throw DBError.cancelled }
            }
            try exec(db, "COMMIT")
        }

        try load("HD.dat", "INSERT OR REPLACE INTO hd VALUES (?,?,?,?)") { s, f in
            guard f.count > 9, f[0] == "HD", let usi = Int64(f[1]) else { return false }
            let status = String(f[5])
            guard status == "A" || status == "E" else { return false }
            sqlite3_bind_int64(s, 1, usi)
            bindText(s, 2, f[4]); bindText(s, 3, status); bindText(s, 4, f[8])
            return true
        }
        try load("AM.dat", "INSERT OR REPLACE INTO am VALUES (?,?)") { s, f in
            guard f.count > 5, f[0] == "AM", let usi = Int64(f[1]) else { return false }
            sqlite3_bind_int64(s, 1, usi)
            bindText(s, 2, f[5])
            return true
        }
        try load("EN.dat", "INSERT OR REPLACE INTO en VALUES (?,?,?,?,?,?,?,?,?,?,?)") { s, f in
            guard f.count > 19, f[0] == "EN", f[5] == "L", let usi = Int64(f[1]) else { return false }
            sqlite3_bind_int64(s, 1, usi)
            for (col, field) in [7, 8, 9, 10, 11, 15, 16, 17, 18, 19].enumerated() { bindText(s, Int32(col + 2), f[field]) }
            return true
        }

        progress(.indexing)
        try exec(db, """
            CREATE TABLE license AS
              SELECT hd.call AS call, hd.status AS status, hd.expires AS expires, am.class AS class,
                     en.name AS name, en.first AS first, en.mi AS mi, en.last AS last, en.suffix AS suffix,
                     en.street AS street, en.city AS city, en.state AS state, en.zip AS zip, en.pobox AS pobox
              FROM hd LEFT JOIN en ON en.usi = hd.usi LEFT JOIN am ON am.usi = hd.usi;
            DROP TABLE hd; DROP TABLE am; DROP TABLE en;
            CREATE INDEX license_call ON license(call);
            CREATE INDEX license_last ON license(last);
            CREATE INDEX license_city ON license(city, state);
            CREATE INDEX license_zip ON license(zip);
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
            """)
        let count = try scalar(db, "SELECT COUNT(*) FROM license") ?? "0"
        try exec(db, "INSERT INTO meta VALUES ('count', '\(count)'), ('builtAt', '\(Date.now.timeIntervalSince1970)'); VACUUM;")
        sqlite3_close(db)
        closed = true

        // Swap in the new file.
        try? FileManager.default.removeItem(at: databaseURL)
        try FileManager.default.moveItem(at: tmp, to: databaseURL)
        var url = databaseURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true      // it can always be downloaded again
        try? url.setResourceValues(values)
    }

    /// The license for one callsign: the active one if there is one, else the latest expired one.
    static func license(_ callSign: String) -> (info: LicenseInfo, expired: Bool)? {
        guard isInstalled, let db = try? open(readOnly: true) else { return nil }
        defer { sqlite3_close(db) }
        let sql = "SELECT * FROM license WHERE call = ? ORDER BY status = 'A' DESC, substr(expires,7,4) || substr(expires,1,2) || substr(expires,4,2) DESC LIMIT 1"
        guard let r = (try? query(db, sql, [callSign.uppercased()]))?.first else { return nil }
        return (r, r.status == "E")
    }

    // MARK: SQLite helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func open(readOnly: Bool) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw DBError.sqlite("can't open the license database")
        }
        return db
    }

    private static func lastError(_ db: OpaquePointer) -> String { String(cString: sqlite3_errmsg(db)) }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DBError.sqlite(lastError(db)) }
    }

    private static func bindText<S: StringProtocol>(_ s: OpaquePointer, _ i: Int32, _ v: S) {
        let t = v.trimmingCharacters(in: .whitespaces)
        sqlite3_bind_text(s, i, t, -1, transient)
    }

    private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> String? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw DBError.sqlite(lastError(db)) }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW, let c = sqlite3_column_text(s, 0) else { return nil }
        return String(cString: c)
    }

    private static func query(_ db: OpaquePointer, _ sql: String, _ args: [String]) throws -> [LicenseInfo] {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw DBError.sqlite(lastError(db)) }
        defer { sqlite3_finalize(s) }
        for (i, a) in args.enumerated() { sqlite3_bind_text(s, Int32(i + 1), a, -1, transient) }
        var cols: [String: Int32] = [:]
        for i in 0..<sqlite3_column_count(s) { cols[String(cString: sqlite3_column_name(s, i))] = i }
        func col(_ name: String) -> String {
            guard let i = cols[name], let c = sqlite3_column_text(s, i) else { return "" }
            return String(cString: c)
        }
        var out: [LicenseInfo] = []
        while sqlite3_step(s) == SQLITE_ROW {
            var info = LicenseInfo()
            info.callSign = col("call")
            let person = [col("first"), col("mi"), col("last"), col("suffix")].filter { !$0.isEmpty }.joined(separator: " ")
            info.name = Tidy.words(person.isEmpty ? col("name") : person)
            let street = col("street")
            info.street = Tidy.words(street.isEmpty ? col("pobox") : street)
            info.city = Tidy.words(col("city"))
            info.state = col("state")
            let zip = col("zip")
            info.zip = zip.count == 9 ? "\(zip.prefix(5))-\(zip.suffix(4))" : zip
            info.licenseClass = FCCLookup.licenseClassName(col("class"))
            info.expires = col("expires")
            info.status = col("status")
            info.source = "FCC license database (downloaded)"
            out.append(info)
        }
        return out
    }
}

// MARK: - Download with progress

final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var moveError: Error?
    private let lock = NSLock()

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            lock.lock()
            continuation = c
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 60 * 60
            let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            session = s
            lock.unlock()
            var req = URLRequest(url: url)
            req.setValue("APRSERJi/1.0 (KC9KKO)", forHTTPHeaderField: "User-Agent")
            s.downloadTask(with: req).resume()
        }
    }

    func cancel() {
        lock.lock(); let s = session; lock.unlock()
        s?.invalidateAndCancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveError = FCCDatabase.DBError.download("the FCC server answered \(http.statusCode)")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let error {
            finish(.failure((error as NSError).code == NSURLErrorCancelled ? FCCDatabase.DBError.cancelled
                            : FCCDatabase.DBError.download(error.localizedDescription)))
        } else if let moveError {
            finish(.failure(moveError))
        } else {
            finish(.success(destination))
        }
    }
}

// MARK: - Reading a large zip without loading it into memory

struct StreamingZip {
    private struct Entry { var method: Int; var compressed: UInt64; var size: UInt64; var localOffset: UInt64 }
    private let url: URL
    private var entries: [String: Entry] = [:]

    init(url: URL) throws {
        self.url = url
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let fileSize = try h.seekToEnd()
        let tailLen = UInt64(min(fileSize, 65_557))
        try h.seek(toOffset: fileSize - tailLen)
        let tail = [UInt8](h.readData(ofLength: Int(tailLen)))
        func u16(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(b[i]) | UInt64(b[i + 1]) << 8 }
        func u32(_ b: [UInt8], _ i: Int) -> UInt64 { u16(b, i) | u16(b, i + 2) << 16 }
        func u64(_ b: [UInt8], _ i: Int) -> UInt64 { u32(b, i) | u32(b, i + 4) << 32 }

        guard tail.count >= 22, let e = stride(from: tail.count - 22, through: 0, by: -1).first(where: { u32(tail, $0) == 0x0605_4B50 })
        else { throw FCCDatabase.DBError.unzip("not a zip file") }
        var count = u16(tail, e + 10)
        var cdSize = u32(tail, e + 12)
        var cdOffset = u32(tail, e + 16)
        // ZIP64 end of central directory (locator just before the classic record)
        if e >= 20, u32(tail, e - 20) == 0x0706_4B50 {
            let z64 = u64(tail, e - 20 + 8)
            try h.seek(toOffset: z64)
            let r = [UInt8](h.readData(ofLength: 56))
            if r.count == 56, u32(r, 0) == 0x0606_4B50 {
                count = u64(r, 32); cdSize = u64(r, 40); cdOffset = u64(r, 48)
            }
        }
        try h.seek(toOffset: cdOffset)
        let cd = [UInt8](h.readData(ofLength: Int(cdSize)))
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, u32(cd, p) == 0x0201_4B50 else { break }
            var entry = Entry(method: Int(u16(cd, p + 10)), compressed: u32(cd, p + 20), size: u32(cd, p + 24),
                              localOffset: u32(cd, p + 42))
            let nameLen = Int(u16(cd, p + 28)), extraLen = Int(u16(cd, p + 30)), commentLen = Int(u16(cd, p + 32))
            let name = String(decoding: cd[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            // ZIP64 extra field: 8-byte values for whichever of size / compressed / offset were 0xFFFFFFFF
            var x = p + 46 + nameLen
            let xEnd = x + extraLen
            while x + 4 <= xEnd {
                let id = u16(cd, x), len = Int(u16(cd, x + 2))
                if id == 0x0001 {
                    var q = x + 4
                    if entry.size == 0xFFFF_FFFF { entry.size = u64(cd, q); q += 8 }
                    if entry.compressed == 0xFFFF_FFFF { entry.compressed = u64(cd, q); q += 8 }
                    if entry.localOffset == 0xFFFF_FFFF { entry.localOffset = u64(cd, q) }
                }
                x += 4 + len
            }
            entries[name.components(separatedBy: "/").last?.uppercased() ?? name.uppercased()] = entry
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    /// Calls `body` with each line (without the line break) of a member file, decompressing as it goes.
    func forEachLine(of name: String, _ body: (Substring) throws -> Void) throws {
        guard let e = entries[name.uppercased()] else { throw FCCDatabase.DBError.unzip("\(name) is missing") }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: e.localOffset)
        let local = [UInt8](h.readData(ofLength: 30))
        guard local.count == 30, local[0] == 0x50, local[1] == 0x4B, local[2] == 0x03, local[3] == 0x04 else {
            throw FCCDatabase.DBError.unzip("\(name) is damaged")
        }
        let skip = UInt64(local[26]) | UInt64(local[27]) << 8
        let skip2 = UInt64(local[28]) | UInt64(local[29]) << 8
        try h.seek(toOffset: e.localOffset + 30 + skip + skip2)

        var pending = Data()
        func emit(_ chunk: Data) throws {
            pending.append(chunk)
            var start = pending.startIndex
            while let nl = pending[start...].firstIndex(of: 0x0A) {
                var line = String(decoding: pending[start..<nl], as: UTF8.self)[...]
                if line.hasSuffix("\r") { line = line.dropLast() }
                try body(line)
                start = pending.index(after: nl)
            }
            pending = Data(pending[start...])
        }

        let chunkSize = 1 << 20
        var remaining = e.compressed
        switch e.method {
        case 0:
            while remaining > 0 {
                let d = h.readData(ofLength: Int(min(UInt64(chunkSize), remaining)))
                if d.isEmpty { break }
                remaining -= UInt64(d.count)
                try emit(d)
            }
        case 8:
            let src = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { src.deallocate(); dst.deallocate(); stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw FCCDatabase.DBError.unzip("can't start decompressing")
            }
            defer { compression_stream_destroy(stream) }
            stream.pointee.src_size = 0
            stream.pointee.dst_ptr = dst
            stream.pointee.dst_size = chunkSize
            var done = false
            while !done {
                if stream.pointee.src_size == 0 && remaining > 0 {
                    let d = h.readData(ofLength: Int(min(UInt64(chunkSize), remaining)))
                    if d.isEmpty { throw FCCDatabase.DBError.unzip("\(name) ends early") }
                    remaining -= UInt64(d.count)
                    d.copyBytes(to: src, count: d.count)
                    stream.pointee.src_ptr = UnsafePointer(src)
                    stream.pointee.src_size = d.count
                }
                let flags = remaining == 0 ? Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = compression_stream_process(stream, flags)
                let produced = chunkSize - stream.pointee.dst_size
                if produced > 0 { try emit(Data(bytes: dst, count: produced)) }
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunkSize
                switch status {
                case COMPRESSION_STATUS_END: done = true
                case COMPRESSION_STATUS_OK:
                    if remaining == 0 && stream.pointee.src_size == 0 && produced == 0 { done = true }
                default: throw FCCDatabase.DBError.unzip("\(name) is damaged")
                }
            }
        default:
            throw FCCDatabase.DBError.unzip("\(name) uses an unsupported compression")
        }
        if !pending.isEmpty { try body(String(decoding: pending, as: UTF8.self)[...]) }
    }
}

// MARK: - Screen section (Find CallSign)

/// Download / update / delete the FCC license database; shows progress while it works.
@MainActor @Observable
final class FCCDatabaseModel {
    static let shared = FCCDatabaseModel()

    var info: FCCDatabase.Info? = FCCDatabase.info()
    var busy = false
    var status = ""
    var fraction: Double?
    var error: String?
    private var job: Task<Void, Never>?

    func download() {
        guard !busy else { return }
        busy = true
        error = nil
        fraction = 0
        status = "Connecting to the FCC…"
        job = Task {
            do {
                try await FCCDatabase.downloadAndBuild { step in
                    Task { @MainActor in FCCDatabaseModel.shared.show(step) }
                }
                info = FCCDatabase.info()
                status = ""
            } catch {
                self.error = error.localizedDescription
                status = ""
            }
            fraction = nil
            busy = false
        }
    }

    func cancel() { job?.cancel() }

    func delete() {
        FCCDatabase.delete()
        info = nil
    }

    private func show(_ step: FCCDatabase.Step) {
        guard busy else { return }
        switch step {
        case let .downloading(done, total):
            let mb = { (b: Int64) in String(format: "%.0f MB", Double(b) / 1_048_576) }
            if total > 0 {
                fraction = Double(done) / Double(total)
                status = "Downloading \(mb(done)) of \(mb(total))…"
            } else {
                fraction = nil
                status = "Downloading \(mb(done))…"
            }
        case let .reading(file):
            fraction = nil
            status = "Reading \(file)…"
        case .indexing:
            fraction = nil
            status = "Building the search index…"
        }
    }
}

struct FCCDatabaseSection: View {
    @State private var model = FCCDatabaseModel.shared
    @State private var confirmDelete = false

    var body: some View {
        Section {
            if model.busy {
                VStack(alignment: .leading, spacing: 6) {
                    if let f = model.fraction { ProgressView(value: f) } else { ProgressView().controlSize(.small) }
                    HStack {
                        Text(model.status).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop", role: .cancel) { model.cancel() }.buttonStyle(.borderless)
                    }
                }
            } else {
                if let info = model.info {
                    LabeledContent("On this device") {
                        Text("\(info.licenses.formatted()) licenses · \(ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file))")
                    }
                    LabeledContent("Downloaded", value: info.builtAt.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    model.download()
                } label: {
                    Label(model.info == nil ? "Download FCC License Database" : "Update FCC License Database",
                          systemImage: "arrow.down.circle")
                }
                if model.info != nil {
                    Button("Delete Downloaded Database", role: .destructive) { confirmDelete = true }
                }
            }
            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } header: {
            Text("Callsign lookup (WHO-IS)")
        } footer: {
            Text(model.info == nil
                 ? "WHO-IS asks callook.info, then HamDB. Download the FCC's complete amateur license file (l_amat.zip from data.fcc.gov, well over 100 MB — use Wi-Fi) to look up US callsigns on this device when those sites can't answer. The FCC updates the file every week; Update downloads it again."
                 : "WHO-IS uses this copy when callook.info and HamDB can't answer, including licenses in their 2-year grace period. The FCC updates the file weekly — Update now and then.")
        }
        .confirmationDialog("Delete the downloaded FCC database?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.delete() }
        } message: {
            Text("WHO-IS goes back to callook.info and HamDB only. You can download it again any time.")
        }
    }
}
