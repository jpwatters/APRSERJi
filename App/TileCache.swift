import Foundation
import MapKit
import SwiftUI

/**
 * Map tiles kept on disk, per tile server, so the map works offline. Tiles the map loads are always cached;
 * the preloader can also fetch an area ahead of time — only from servers whose policy allows it.
 */
enum TileCache {
    /** Cached tiles younger than this are used without asking the server again. */
    static let freshSeconds: TimeInterval = 7 * 24 * 3600

    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("APRSERJi-Tiles", isDirectory: true)
    }

    static func file(_ preset: TilePreset, z: Int, x: Int, y: Int) -> URL {
        root.appendingPathComponent(preset.folder, isDirectory: true)
            .appendingPathComponent("\(z)/\(x)/\(y).png")
    }

    static func read(_ preset: TilePreset, z: Int, x: Int, y: Int) -> (data: Data, age: TimeInterval)? {
        let url = file(preset, z: z, x: x, y: y)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return (data, Date().timeIntervalSince(modified))
    }

    static func write(_ preset: TilePreset, z: Int, x: Int, y: Int, data: Data) {
        let url = file(preset, z: z, x: x, y: y)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func download(_ preset: TilePreset, z: Int, x: Int, y: Int, url: URL, completion: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        request.setValue("APRSERJi/\(version) (+https://github.com/kj4dxk/APRSERJi)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
               let data, !data.isEmpty {
                write(preset, z: z, x: x, y: y, data: data)
                completion(data)
            } else {
                completion(nil)
            }
        }.resume()
    }

    /** Total size and tile count on disk. */
    static func usage() -> (bytes: Int64, tiles: Int) {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, 0) }
        var bytes: Int64 = 0
        var tiles = 0
        for case let url as URL in walker where url.pathExtension == "png" {
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            tiles += 1
        }
        return (bytes, tiles)
    }

    static func clear() { try? FileManager.default.removeItem(at: root) }

    /** Deletes the least recently used tiles until the cache fits [maxBytes]. Returns how many were removed. */
    @discardableResult
    static func prune(maxBytes: Int64) -> Int {
        guard maxBytes > 0, let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return 0 }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for case let url as URL in walker where url.pathExtension == "png" {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            files.append((url, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > maxBytes else { return 0 }
        var removed = 0
        for file in files.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
            removed += 1
        }
        return removed
    }

    /** The cache size limit from Setup, in bytes (0 for no limit). */
    static var budgetBytes: Int64 {
        Int64(UserDefaults.standard.object(forKey: "tileBudgetMB") as? Int ?? 1024) * 1_048_576
    }

    /** Slippy-map tile numbers covering a region at one zoom level. */
    static func tiles(in region: MKCoordinateRegion, zoom z: Int) -> [(x: Int, y: Int)] {
        let n = Double(1 << z)
        func x(_ lon: Double) -> Int { Int(floor((lon + 180) / 360 * n)) }
        func y(_ lat: Double) -> Int {
            let r = max(-85.0511, min(85.0511, lat)) * .pi / 180
            return Int(floor((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * n))
        }
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let east = region.center.longitude + region.span.longitudeDelta / 2
        let north = region.center.latitude + region.span.latitudeDelta / 2
        let south = region.center.latitude - region.span.latitudeDelta / 2
        let maxIndex = Int(n) - 1
        let xs = max(0, x(west))...min(maxIndex, x(east))
        let ys = max(0, y(north))...min(maxIndex, y(south))
        return xs.flatMap { tx in ys.map { (tx, $0) } }
    }
}

extension TilePreset {
    var folder: String { self == .project ? "pdeffenb" : "openstreetmap" }
    /**
     * The OpenStreetMap Foundation's tile policy forbids bulk downloading from tile.openstreetmap.org, so
     * preloading is offered only for the project's own server. Tiles you view are cached either way.
     */
    var allowsPreload: Bool { self == .project }
}

/** Downloads every tile of the visible area for a range of zoom levels, two at a time. */
@MainActor
final class TilePreloader: ObservableObject {
    static let shared = TilePreloader()
    static let maximumTiles = 5_000

    @Published private(set) var busy = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var failed = 0
    @Published var usage = TileCache.usage()
    private var job: Task<Void, Never>?

    func plan(_ preset: TilePreset, region: MKCoordinateRegion, from: Int, to: Int) -> [(z: Int, x: Int, y: Int)] {
        (from...max(from, to)).flatMap { z in TileCache.tiles(in: region, zoom: z).map { (z, $0.x, $0.y) } }
    }

    func start(_ preset: TilePreset, tiles: [(z: Int, x: Int, y: Int)]) {
        guard !busy, preset.allowsPreload else { return }
        let work = Array(tiles.prefix(Self.maximumTiles))
        busy = true
        done = 0
        failed = 0
        total = work.count
        job = Task {
            await withTaskGroup(of: Bool.self) { group in
                var next = 0
                while next < min(2, work.count) {
                    let tile = work[next]
                    next += 1
                    group.addTask { await TilePreloader.fetch(preset, tile) }
                }
                while let ok = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    done += 1
                    if !ok { failed += 1 }
                    if next < work.count {
                        let tile = work[next]
                        next += 1
                        group.addTask { await TilePreloader.fetch(preset, tile) }
                    }
                }
            }
            usage = TileCache.usage()
            busy = false
        }
    }

    /** One tile: skipped when a fresh copy is cached, otherwise downloaded into the cache. */
    nonisolated static func fetch(_ preset: TilePreset, _ tile: (z: Int, x: Int, y: Int)) async -> Bool {
        if let cached = TileCache.read(preset, z: tile.z, x: tile.x, y: tile.y), cached.age < TileCache.freshSeconds {
            return true
        }
        guard let url = URL(string: preset.template.replacingOccurrences(of: "{z}", with: "\(tile.z)")
            .replacingOccurrences(of: "{x}", with: "\(tile.x)")
            .replacingOccurrences(of: "{y}", with: "\(tile.y)")) else { return false }
        return await withCheckedContinuation { continuation in
            TileCache.download(preset, z: tile.z, x: tile.x, y: tile.y, url: url) { data in
                continuation.resume(returning: data != nil)
            }
        }
    }

    func cancel() { job?.cancel() }

    func clear() {
        TileCache.clear()
        usage = TileCache.usage()
    }
}

/** Setup ▸ Offline maps. */
struct OfflineMapsSection: View {
    @ObservedObject private var loader = TilePreloader.shared
    @AppStorage("tilePreset") private var tilePreset: TilePreset = .project
    @State private var extraLevels = 3
    @AppStorage("tileBudgetMB") private var budget = 1024

    var body: some View {
        Section {
            LabeledContent("On this device",
                           value: "\(loader.usage.tiles.formatted()) tiles · \(ByteCountFormatter.string(fromByteCount: loader.usage.bytes, countStyle: .file))")
            if loader.busy {
                ProgressView(value: Double(loader.done), total: Double(max(1, loader.total))) {
                    Text("Downloading \(loader.done) of \(loader.total) tiles" + (loader.failed > 0 ? " · \(loader.failed) failed" : ""))
                }
                Button("Stop", role: .cancel) { loader.cancel() }
            } else if tilePreset.allowsPreload {
                Stepper("Zoom levels \(MapViewport.zoom)–\(min(18, MapViewport.zoom + extraLevels))",
                        value: $extraLevels, in: 0...6)
                let count = MapViewport.region.map {
                    loader.plan(tilePreset, region: $0, from: MapViewport.zoom, to: min(18, MapViewport.zoom + extraLevels)).count
                } ?? 0
                Button("Download visible map area (\(count.formatted()) tiles)") {
                    if let region = MapViewport.region {
                        loader.start(tilePreset, tiles: loader.plan(tilePreset, region: region, from: MapViewport.zoom,
                                                                     to: min(18, MapViewport.zoom + extraLevels)))
                    }
                }
                .disabled(count == 0 || count > TilePreloader.maximumTiles)
                if count > TilePreloader.maximumTiles {
                    Text("That is more than \(TilePreloader.maximumTiles.formatted()) tiles. Zoom the map in or choose fewer levels.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Picker("Keep at most", selection: $budget) {
                ForEach([250, 500, 1024, 2048, 5120, 0], id: \.self) { mb in
                    Text(mb == 0 ? "No limit" : mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB").tag(mb)
                }
            }
            .onChange(of: budget) { _, _ in
                DispatchQueue.global(qos: .utility).async {
                    TileCache.prune(maxBytes: TileCache.budgetBytes)
                    let usage = TileCache.usage()
                    DispatchQueue.main.async { loader.usage = usage }
                }
            }
            Button("Clear map cache", role: .destructive) { loader.clear() }
                .disabled(loader.busy)
        } header: {
            Text("Offline maps")
        } footer: {
            Text(tilePreset.allowsPreload
                 ? "Every tile the map shows is kept for offline use. Download visible map area fetches the area on the map now, from its current zoom level in, from the \(tilePreset.rawValue) server."
                 : "Every tile the map shows is kept for offline use. The OpenStreetMap tile policy forbids bulk downloads, so switch the map's tiles to pdeffenb to download an area ahead of time.")
        }
        .onAppear { loader.usage = TileCache.usage() }
    }
}
