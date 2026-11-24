import Compression
import Foundation
import ImageIO
import MapKit
import SwiftUI
import UniformTypeIdentifiers

// State and county boundaries, Interstates, US highways, state roads and county roads.
// Drawn from the Census Bureau's TIGERweb map service when online, and from files the user imports
// (Census TIGER/Line or cartographic boundary shapefiles, GeoJSON, KML/KMZ) for offline use.

/** One kind of boundary or road line. */
enum ReferenceKind: String, CaseIterable, Identifiable, Codable {
    case states, counties, interstates, usHighways, stateRoads, countyRoads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .states: return "State boundaries"
        case .counties: return "County boundaries"
        case .interstates: return "Interstates"
        case .usHighways: return "US highways"
        case .stateRoads: return "State roads"
        case .countyRoads: return "County roads"
        }
    }

    /** The UserDefaults key that turns this kind on. */
    var key: String { "ref_" + rawValue }

    /** On unless the user turns it off: boundaries, Interstates and US highways. */
    var onByDefault: Bool { [.states, .counties, .interstates, .usHighways].contains(self) }

    var isRoad: Bool { ![.states, .counties].contains(self) }

    /** TIGER route type (RTTYP) for roads. */
    var routeType: String? {
        switch self {
        case .interstates: return "I"
        case .usHighways: return "U"
        case .stateRoads: return "S"
        case .countyRoads: return "C"
        default: return nil
        }
    }

    /** Line color for imported data (RGB 0–1). The online layers use the Census Bureau's own colors for roads. */
    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .states: return (0.47, 0.12, 0.55)
        case .counties: return (0.66, 0.38, 0.78)
        case .interstates: return (0.86, 0.29, 0.17)
        case .usHighways: return (0.95, 0.55, 0.20)
        case .stateRoads: return (0.96, 0.68, 0.32)
        case .countyRoads: return (0.55, 0.55, 0.55)
        }
    }

    /** Line width in points for imported data. */
    var width: CGFloat {
        switch self {
        case .states: return 2.5
        case .counties: return 1.2
        case .interstates: return 2.5
        case .usHighways: return 2.0
        case .stateRoads: return 1.6
        case .countyRoads: return 1.2
        }
    }

    /** Smallest map zoom at which imported lines of this kind are drawn (keeps wide views fast and readable). */
    var minimumZoom: Int {
        switch self {
        case .states: return 0
        case .counties: return 5
        case .interstates: return 4
        case .usHighways: return 6
        case .stateRoads: return 7
        case .countyRoads: return 9
        }
    }

    /** The order lines are drawn in: boundaries under roads, bigger roads on top. */
    static let drawingOrder: [ReferenceKind] = [.counties, .states, .countyRoads, .stateRoads, .usHighways, .interstates]
}

/** Where boundary and road lines come from. */
enum ReferenceSource: String, CaseIterable, Identifiable {
    case online = "Census Bureau (online)", imported = "Imported files only", both = "Both"
    var id: String { rawValue }
}

/** What the map draws for boundaries and roads. */
struct ReferenceSettings: Equatable {
    var kinds: Set<ReferenceKind> = []
    var names = false
    var source: ReferenceSource = .online
    /** Changes whenever imported files are added, removed, shown or hidden. */
    var importedRevision = 0

    static func load(revision: Int) -> ReferenceSettings {
        let defaults = UserDefaults.standard
        var settings = ReferenceSettings()
        for kind in ReferenceKind.allCases where (defaults.object(forKey: kind.key) as? Bool) ?? kind.onByDefault {
            settings.kinds.insert(kind)
        }
        settings.names = false // names are shown by right-clicking or pressing and holding the map instead
        settings.source = ReferenceSource(rawValue: defaults.string(forKey: "refSource") ?? "") ?? .online
        settings.importedRevision = revision
        return settings
    }

    var drawsOnline: Bool { source != .imported && !kinds.isEmpty }
    var drawsImported: Bool { source != .online && !kinds.isEmpty }
}

// MARK: - Online layers (TIGERweb)

/** Tile math shared by the online and imported layers. */
enum WebMercator {
    static let radius = 20_037_508.342789244

    /** The tile's extent in Web Mercator meters: (xmin, ymin, xmax, ymax). */
    static func bounds(_ path: MKTileOverlayPath) -> (Double, Double, Double, Double) {
        let size = 2 * radius / Double(1 << path.z)
        let xmin = -radius + Double(path.x) * size
        let ymax = radius - Double(path.y) * size
        return (xmin, ymax - size, xmin + size, ymax)
    }

    static func x(_ lon: Double) -> Double { lon * radius / 180 }
    static func y(_ lat: Double) -> Double {
        let clamped = max(-85.05, min(85.05, lat))
        return log(tan((90 + clamped) * .pi / 360)) * radius / .pi
    }
    static func lon(_ x: Double) -> Double { x / radius * 180 }
    static func lat(_ y: Double) -> Double { atan(exp(y / radius * .pi)) * 360 / .pi - 90 }
}

/** Census TIGERweb boundaries or roads, fetched as images for each map tile and cached on disk. */
final class TigerTiles: MKTileOverlay {
    enum Content: Equatable {
        case boundaries(states: Bool, counties: Bool, names: Bool)
        case roads(Set<ReferenceKind>)
    }

    static let service = "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/"
    /** Cached tiles younger than this are used without asking the server again; older ones only when offline. */
    static let freshSeconds: TimeInterval = 30 * 24 * 3600

    let content: Content

    init(content: Content) {
        self.content = content
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 512, height: 512)
        canReplaceMapContent = false
        minimumZ = 2
        maximumZ = 18
    }

    /** A short name for the cache folder, unique per content. */
    var cacheKey: String {
        switch content {
        case let .boundaries(states, counties, names):
            return "tiger-bnd-\(states ? "s" : "")\(counties ? "c" : "")\(names ? "n" : "")"
        case let .roads(kinds):
            return "tiger-roads-" + kinds.compactMap(\.routeType).sorted().joined()
        }
    }

    private func requests(_ path: MKTileOverlayPath) -> (lines: URL, labels: URL?) {
        let (xmin, ymin, xmax, ymax) = WebMercator.bounds(path)
        let scale = max(1, min(3, Int(path.contentScaleFactor.rounded())))
        func url(_ service: String, _ extra: [URLQueryItem]) -> URL {
            var parts = URLComponents(string: Self.service + service + "/MapServer/export")!
            parts.queryItems = [
                URLQueryItem(name: "bbox", value: String(format: "%.2f,%.2f,%.2f,%.2f", xmin, ymin, xmax, ymax)),
                URLQueryItem(name: "bboxSR", value: "3857"), URLQueryItem(name: "imageSR", value: "3857"),
                URLQueryItem(name: "size", value: "\(512 * scale),\(512 * scale)"),
                URLQueryItem(name: "dpi", value: "\(96 * scale)"),
                URLQueryItem(name: "format", value: "png32"), URLQueryItem(name: "transparent", value: "true"),
                URLQueryItem(name: "f", value: "image"),
            ] + extra
            return parts.url!
        }
        switch content {
        case let .boundaries(states, counties, names):
            let layers = (states ? ["80"] : []) + (counties ? ["82"] : [])
            let labelLayers = (states ? ["81"] : []) + (counties ? ["83"] : [])
            let lines = url("tigerWMS_Current", [URLQueryItem(name: "layers", value: "show:" + layers.joined(separator: ","))])
            let labels = names ? url("tigerWMS_Current", [URLQueryItem(name: "layers", value: "show:" + labelLayers.joined(separator: ","))]) : nil
            return (lines, labels)
        case let .roads(kinds):
            let types = kinds.compactMap(\.routeType).sorted().map { "'\($0)'" }.joined(separator: ",")
            let filter = "RTTYP IN (\(types))"
            var defs: [String: String] = [:]
            for layer in 0...8 { defs[String(layer)] = filter }
            let json = String(data: try! JSONSerialization.data(withJSONObject: defs, options: [.sortedKeys]), encoding: .utf8)!
            return (url("Transportation", [URLQueryItem(name: "layers", value: "show:0,1,2,3,4,5,6,7,8"),
                                           URLQueryItem(name: "layerDefs", value: json)]), nil)
        }
    }

    private func cacheFile(_ path: MKTileOverlayPath) -> URL {
        TileCache.root.appendingPathComponent("reference/\(cacheKey)/\(path.z)/\(path.x)/\(path.y)@\(Int(path.contentScaleFactor)).png")
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let file = cacheFile(path)
        let cached = try? Data(contentsOf: file)
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let cached, !cached.isEmpty, Date().timeIntervalSince(modified) < Self.freshSeconds {
            result(cached, nil)
            return
        }
        let (linesURL, labelsURL) = requests(path)
        let content = self.content
        Task.detached(priority: .utility) {
            guard let lines = await Self.fetch(linesURL) else {
                if let cached { result(cached, nil) } else { result(nil, URLError(.notConnectedToInternet)) }
                return
            }
            var labels: Data?
            if let labelsURL { labels = await Self.fetch(labelsURL) }
            var tile = lines
            if case let .boundaries(states, counties, _) = content {
                tile = ReferenceImage.recolorBoundaries(lines, labels: labels, both: states && counties, statesOnly: states && !counties) ?? lines
            }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? tile.write(to: file, options: .atomic)
            result(tile, nil)
        }
    }

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        request.setValue("APRSERJi/\(version) (+https://github.com/kj4dxk/APRSERJi)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        return data
    }
}

/** Pixel work on tile images. */
enum ReferenceImage {
    /** A fully transparent 1×1 PNG, for tiles with nothing on them. */
    static let empty: Data = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return png(context.makeImage()!) ?? Data()
    }()

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /**
     * TIGERweb draws state lines dark gray and county lines light gray, too faint over a map. Repaint them
     * purple (states darker and bolder), then lay the name labels on top.
     */
    static func recolorBoundaries(_ data: Data, labels: Data?, both: Bool, statesOnly: Bool) -> Data? {
        guard let image = decode(data) else { return nil }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let state = ReferenceKind.states.rgb, county = ReferenceKind.counties.rgb
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = pixels[i + 3]
            guard alpha > 0 else { continue }
            let gray = Int(pixels[i]) * 255 / Int(alpha)
            let isState = statesOnly || (both && gray < 132)
            let (r, g, b) = isState ? state : county
            let a = min(255, Int(alpha) * (isState ? 5 : 4) / 4)
            pixels[i] = UInt8(r * CGFloat(a)); pixels[i + 1] = UInt8(g * CGFloat(a)); pixels[i + 2] = UInt8(b * CGFloat(a))
            pixels[i + 3] = UInt8(a)
        }
        if let labels, let labelImage = decode(labels) {
            context.draw(labelImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let out = context.makeImage() else { return nil }
        return png(out)
    }
}

// MARK: - Imported files

/** One line or outline from an imported file, in degrees, as lon/lat pairs. */
struct ReferenceFeature {
    let kind: ReferenceKind
    let closed: Bool
    let parts: [[Float]]
    /** The county, state or road name, when the file has one. */
    let name: String?
    let minLon: Float, minLat: Float, maxLon: Float, maxLat: Float

    init?(kind: ReferenceKind, closed: Bool, parts: [[Float]], name: String? = nil) {
        let parts = parts.filter { $0.count >= 4 }
        guard !parts.isEmpty else { return nil }
        var minLon = Float.greatestFiniteMagnitude, minLat = Float.greatestFiniteMagnitude
        var maxLon = -Float.greatestFiniteMagnitude, maxLat = -Float.greatestFiniteMagnitude
        for part in parts {
            for i in stride(from: 0, to: part.count - 1, by: 2) {
                minLon = min(minLon, part[i]); maxLon = max(maxLon, part[i])
                minLat = min(minLat, part[i + 1]); maxLat = max(maxLat, part[i + 1])
            }
        }
        self.kind = kind; self.closed = closed; self.parts = parts
        self.name = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        self.minLon = minLon; self.minLat = minLat; self.maxLon = maxLon; self.maxLat = maxLat
    }
}

/** An imported file as listed in Setup. */
struct ReferenceFileInfo: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var counts: [String: Int]
    var points: Int
    var added = Date()
    var visible = true

    var summary: String {
        ReferenceKind.allCases.compactMap { kind in counts[kind.rawValue].map { "\($0) \(kind.title.lowercased())" } }
            .joined(separator: " · ") + " · \(points.formatted()) points"
    }
}

enum ReferenceImportError: LocalizedError {
    case unreadable(String), projected, empty, network(String)
    var errorDescription: String? {
        switch self {
        case let .unreadable(why): return why
        case .projected: return "The shapefile uses projected coordinates. Use a file in latitude/longitude (NAD83 or WGS84), such as the Census Bureau's."
        case .empty: return "No boundaries or roads were found. Choose what the file holds under “Import as” and try again."
        case let .network(why): return why
        }
    }
}

/** Imported boundary and road files: kept in Application Support, loaded into memory and indexed for drawing. */
final class ReferenceStore: ObservableObject {
    static let shared = ReferenceStore()

    @Published var files: [ReferenceFileInfo] = [] { didSet { saveIndex() } }
    @Published private(set) var revision = 0
    @Published var busy: String?

    private let lock = NSLock()
    private var loaded: [UUID: [ReferenceFeature]] = [:]
    /** Feature indexes per 1° cell, per file. */
    private var grids: [UUID: [Int: [Int]]] = [:]

    /** Where imported files are kept; tests point this elsewhere. */
    static var folderOverride: URL?

    private var folder: URL {
        let base = Self.folderOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("APRSERJi/Reference", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private var indexFile: URL { folder.appendingPathComponent("index.json") }
    private func dataFile(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).bin") }

    private init() {
        if let data = try? Data(contentsOf: indexFile), let list = try? JSONDecoder().decode([ReferenceFileInfo].self, from: data) {
            files = list
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for info in self.files { self.load(info.id) }
            DispatchQueue.main.async { self.revision += 1 }
        }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(files) { try? data.write(to: indexFile, options: .atomic) }
    }

    func setVisible(_ id: UUID, _ visible: Bool) {
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        files[i].visible = visible
        revision += 1
    }

    func remove(_ id: UUID) {
        files.removeAll { $0.id == id }
        lock.lock(); loaded[id] = nil; grids[id] = nil; lock.unlock()
        try? FileManager.default.removeItem(at: dataFile(id))
        revision += 1
    }

    /** Features of the given kinds near a lon/lat box, from the visible files. Safe from any thread. */
    func features(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double, kinds: Set<ReferenceKind>, visible: Set<UUID>) -> [ReferenceFeature] {
        lock.lock(); defer { lock.unlock() }
        var out: [ReferenceFeature] = []
        let x0 = Int(floor(minLon)), x1 = Int(floor(maxLon)), y0 = Int(floor(minLat)), y1 = Int(floor(maxLat))
        let wide = (x1 - x0 + 1) * (y1 - y0 + 1) > 400
        for (id, list) in loaded where visible.contains(id) {
            var seen = Set<Int>()
            let candidates: [Int]
            if wide {
                candidates = Array(list.indices)
            } else {
                var c: [Int] = []
                for x in x0...x1 { for y in y0...y1 { c += grids[id]?[Self.cell(x, y)] ?? [] } }
                candidates = c
            }
            for i in candidates where seen.insert(i).inserted {
                let f = list[i]
                guard kinds.contains(f.kind), Double(f.maxLon) >= minLon, Double(f.minLon) <= maxLon,
                      Double(f.maxLat) >= minLat, Double(f.minLat) <= maxLat else { continue }
                out.append(f)
            }
        }
        return out
    }

    private static func cell(_ x: Int, _ y: Int) -> Int { (x + 360) * 1000 + (y + 180) }

    /** State, county and nearby road names at a spot, from the visible imported files (works offline). */
    func place(at c: CLLocationCoordinate2D, radius: Double = 150) -> PlaceInfo {
        let visible = Set(files.filter(\.visible).map(\.id))
        let lon = Float(c.longitude), lat = Float(c.latitude)
        let metersPerLon = 111_320 * cos(c.latitude * .pi / 180), metersPerLat = 110_574.0
        let dLon = Float(radius / max(1, metersPerLon)), dLat = Float(radius / metersPerLat)
        var info = PlaceInfo(source: "your imported boundary and road files")
        var roads: [(name: String, type: String, distance: Double)] = []
        lock.lock()
        for (id, list) in loaded where visible.contains(id) {
            for f in list {
                guard lon >= f.minLon - dLon, lon <= f.maxLon + dLon, lat >= f.minLat - dLat, lat <= f.maxLat + dLat else { continue }
                switch f.kind {
                case .states, .counties:
                    guard f.closed, let name = f.name, Self.contains(f, lon, lat) else { continue }
                    if f.kind == .states { info.state = info.state ?? name } else { info.county = info.county ?? name }
                default:
                    guard let name = f.name else { continue }
                    var best = Double.greatestFiniteMagnitude
                    for part in f.parts {
                        var i = 0
                        while i + 3 < part.count {
                            let ax = Double(part[i] - lon) * metersPerLon, ay = Double(part[i + 1] - lat) * metersPerLat
                            let bx = Double(part[i + 2] - lon) * metersPerLon, by = Double(part[i + 3] - lat) * metersPerLat
                            let dx = bx - ax, dy = by - ay, len = dx * dx + dy * dy
                            let t = len > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len)) : 0
                            best = min(best, hypot(ax + t * dx, ay + t * dy))
                            i += 2
                        }
                    }
                    if best <= radius { roads.append((name, f.kind.routeType ?? "", best)) }
                }
            }
        }
        lock.unlock()
        roads.sort { $0.distance < $1.distance }
        info.roads = PlaceLookup.rankRoads(roads.map { ($0.name, $0.type) })
        return info
    }

    /** Even-odd point-in-polygon over all rings. */
    private static func contains(_ f: ReferenceFeature, _ x: Float, _ y: Float) -> Bool {
        var inside = false
        for part in f.parts {
            let n = part.count / 2
            var j = n - 1
            for i in 0..<n {
                let xi = part[2 * i], yi = part[2 * i + 1], xj = part[2 * j], yj = part[2 * j + 1]
                if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
                j = i
            }
        }
        return inside
    }

    private func index(_ id: UUID, _ list: [ReferenceFeature]) {
        var grid: [Int: [Int]] = [:]
        for (i, f) in list.enumerated() {
            let x0 = Int(floor(f.minLon)), x1 = Int(floor(f.maxLon)), y0 = Int(floor(f.minLat)), y1 = Int(floor(f.maxLat))
            if (x1 - x0 + 1) * (y1 - y0 + 1) > 2_000 { continue }
            for x in x0...x1 { for y in y0...y1 { grid[Self.cell(x, y), default: []].append(i) } }
        }
        lock.lock(); loaded[id] = list; grids[id] = grid; lock.unlock()
    }

    private func load(_ id: UUID) {
        guard let data = try? Data(contentsOf: dataFile(id)), let list = Self.decode(data) else { return }
        index(id, list)
    }

    // MARK: Adding files

    /** Imports a file; `kind` nil detects each feature's kind from its attributes or the file name. */
    @MainActor
    func importFile(_ url: URL, as kind: ReferenceKind?, onlyState: String? = nil, displayName: String? = nil) async throws {
        let name = displayName ?? url.deletingPathExtension().lastPathComponent
        busy = "Reading \(url.lastPathComponent)…"
        defer { busy = nil }
        let features = try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            return try ReferenceParser.parse(data, fileName: url.lastPathComponent, kind: kind, onlyState: onlyState)
        }.value
        try add(features, name: name)
    }

    @MainActor
    private func add(_ features: [ReferenceFeature], name: String) throws {
        guard !features.isEmpty else { throw ReferenceImportError.empty }
        var counts: [String: Int] = [:]
        var points = 0
        for f in features {
            counts[f.kind.rawValue, default: 0] += 1
            points += f.parts.reduce(0) { $0 + $1.count / 2 }
        }
        let info = ReferenceFileInfo(name: name, counts: counts, points: points)
        try Self.encode(features).write(to: dataFile(info.id), options: .atomic)
        index(info.id, features)
        files.append(info)
        revision += 1
    }

    /** Downloads a state's roads and county lines, and the national state lines, from the Census Bureau. */
    @MainActor
    func downloadState(_ state: USState) async throws {
        let tasks: [(title: String, url: String, onlyState: String?, kind: ReferenceKind?)] = [
            ("\(state.name) roads", "https://www2.census.gov/geo/tiger/TIGER2025/PRISECROADS/tl_2025_\(state.fips)_prisecroads.zip", nil, nil),
            ("\(state.name) counties", "https://www2.census.gov/geo/tiger/GENZ2024/shp/cb_2024_us_county_500k.zip", state.fips, .counties),
        ] + (files.contains { $0.name == "US state boundaries" } ? [] :
                [("US state boundaries", "https://www2.census.gov/geo/tiger/GENZ2024/shp/cb_2024_us_state_500k.zip", nil, .states)])
        for task in tasks {
            if let old = files.first(where: { $0.name == task.title }) { remove(old.id) }
            busy = "Downloading \(task.title)…"
            var request = URLRequest(url: URL(string: task.url)!, timeoutInterval: 120)
            request.setValue("APRSERJi (+https://github.com/kj4dxk/APRSERJi)", forHTTPHeaderField: "User-Agent")
            let data: Data
            do {
                let (body, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    busy = nil
                    throw ReferenceImportError.network("The Census Bureau didn't have \(URL(string: task.url)!.lastPathComponent).")
                }
                data = body
            } catch let error as ReferenceImportError {
                throw error
            } catch {
                busy = nil
                throw ReferenceImportError.network("Couldn't download \(task.title): \(error.localizedDescription)")
            }
            busy = "Reading \(task.title)…"
            let fileName = URL(string: task.url)!.lastPathComponent
            let features = try await Task.detached(priority: .userInitiated) {
                try ReferenceParser.parse(data, fileName: fileName, kind: task.kind, onlyState: task.onlyState)
            }.value
            try add(features, name: task.title)
        }
        busy = nil
    }

    // MARK: Storage format

    private static func encode(_ features: [ReferenceFeature]) -> Data {
        var out = Data("APRF2".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        u32(features.count)
        let kinds = ReferenceKind.allCases
        for f in features {
            out.append(UInt8(kinds.firstIndex(of: f.kind)!))
            out.append(f.closed ? 1 : 0)
            u32(f.parts.count)
            for part in f.parts {
                u32(part.count)
                part.withUnsafeBytes { out.append(contentsOf: $0) }
            }
            let name = Data((f.name ?? "").utf8.prefix(200))
            u32(name.count)
            out.append(name)
        }
        return out
    }

    private static func decode(_ data: Data) -> [ReferenceFeature]? {
        let version2 = data.starts(with: Data("APRF2".utf8))
        guard version2 || data.starts(with: Data("APRF1".utf8)) else { return nil }
        var offset = 5
        let bytes = [UInt8](data)
        func u32() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            let v = Int(UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
            offset += 4
            return v
        }
        guard let count = u32() else { return nil }
        let kinds = ReferenceKind.allCases
        var out: [ReferenceFeature] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 2 <= bytes.count, Int(bytes[offset]) < kinds.count else { return nil }
            let kind = kinds[Int(bytes[offset])], closed = bytes[offset + 1] == 1
            offset += 2
            guard let partCount = u32() else { return nil }
            var parts: [[Float]] = []
            for _ in 0..<partCount {
                guard let n = u32(), offset + n * 4 <= bytes.count else { return nil }
                let part = bytes.withUnsafeBufferPointer { buffer -> [Float] in
                    let raw = UnsafeRawPointer(buffer.baseAddress! + offset)
                    return (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
                }
                offset += n * 4
                parts.append(part)
            }
            var name: String?
            if version2 {
                guard let n = u32(), offset + n <= bytes.count else { return nil }
                name = String(decoding: bytes[offset..<(offset + n)], as: UTF8.self)
                offset += n
            }
            if let f = ReferenceFeature(kind: kind, closed: closed, parts: parts, name: name) { out.append(f) }
        }
        return out
    }
}

/** Draws imported boundaries and roads into map tiles. */
final class ImportedReferenceTiles: MKTileOverlay {
    let kinds: Set<ReferenceKind>
    let visible: Set<UUID>

    init(kinds: Set<ReferenceKind>, visible: Set<UUID>) {
        self.kinds = kinds
        self.visible = visible
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 512, height: 512)
        canReplaceMapContent = false
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let kinds = self.kinds, visible = self.visible
        DispatchQueue.global(qos: .userInitiated).async {
            result(Self.render(path, kinds: kinds, visible: visible), nil)
        }
    }

    static func render(_ path: MKTileOverlayPath, kinds: Set<ReferenceKind>, visible: Set<UUID>) -> Data {
        // MapKit's 512-point tiles at zoom z cover what 256-point tiles cover at z + 1.
        let zoom = path.z + 1
        let shown = kinds.filter { $0.minimumZoom <= zoom }
        guard !shown.isEmpty else { return ReferenceImage.empty }
        let (xmin, ymin, xmax, ymax) = WebMercator.bounds(path)
        let pad = (xmax - xmin) * 0.02
        let features = ReferenceStore.shared.features(
            minLon: WebMercator.lon(xmin - pad), minLat: WebMercator.lat(ymin - pad),
            maxLon: WebMercator.lon(xmax + pad), maxLat: WebMercator.lat(ymax + pad), kinds: shown, visible: visible)
        guard !features.isEmpty else { return ReferenceImage.empty }
        let scale = max(1, min(3, path.contentScaleFactor))
        let pixels = Int(512 * scale)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ReferenceImage.empty }
        let perMeter = Double(pixels) / (xmax - xmin)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for kind in ReferenceKind.drawingOrder where shown.contains(kind) {
            let (r, g, b) = kind.rgb
            context.setStrokeColor(red: r, green: g, blue: b, alpha: 0.9)
            context.setLineWidth(kind.width * scale)
            let pathRef = CGMutablePath()
            for f in features where f.kind == kind {
                for part in f.parts {
                    var last = CGPoint(x: -1e9, y: -1e9)
                    var started = false
                    for i in stride(from: 0, to: part.count - 1, by: 2) {
                        let px = (WebMercator.x(Double(part[i])) - xmin) * perMeter
                        let py = (WebMercator.y(Double(part[i + 1])) - ymin) * perMeter
                        let p = CGPoint(x: px, y: py)
                        if started {
                            if abs(p.x - last.x) + abs(p.y - last.y) < 0.8 * scale { continue }
                            pathRef.addLine(to: p)
                        } else {
                            pathRef.move(to: p)
                            started = true
                        }
                        last = p
                    }
                    if f.closed && started { pathRef.closeSubpath() }
                }
            }
            context.addPath(pathRef)
            context.strokePath()
        }
        guard let image = context.makeImage() else { return ReferenceImage.empty }
        return ReferenceImage.png(image) ?? ReferenceImage.empty
    }
}

// MARK: - File formats

/** Reads zipped shapefiles, GeoJSON and KML/KMZ into features. */
enum ReferenceParser {
    static func parse(_ data: Data, fileName: String, kind: ReferenceKind?, onlyState: String?) throws -> [ReferenceFeature] {
        let lower = fileName.lowercased()
        let hint = kind ?? hintFromName(lower)
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            let entries = try Zip.entries(data)
            if let shp = entries.first(where: { $0.name.lowercased().hasSuffix(".shp") }) {
                let base = String(shp.name.dropLast(4))
                if let prj = entries.first(where: { $0.name.caseInsensitiveCompare(base + ".prj") == .orderedSame }),
                   let text = String(data: try Zip.extract(prj, from: data), encoding: .utf8), text.uppercased().hasPrefix("PROJCS") {
                    throw ReferenceImportError.projected
                }
                let dbfEntry = entries.first(where: { $0.name.caseInsensitiveCompare(base + ".dbf") == .orderedSame })
                let records = try dbfEntry.map { try DBF.records(try Zip.extract($0, from: data)) } ?? []
                let hintKind = kind ?? hintFromName(shp.name.lowercased()) ?? hint
                return try Shapefile.features(try Zip.extract(shp, from: data), records: records, kind: hintKind, onlyState: onlyState)
            }
            if let kml = entries.first(where: { $0.name.lowercased().hasSuffix(".kml") }) {
                return KMLReader.features(try Zip.extract(kml, from: data), kind: hint ?? hintFromName(kml.name.lowercased()), onlyState: onlyState)
            }
            if let json = entries.first(where: { $0.name.lowercased().hasSuffix("json") }) {
                return try GeoJSON.features(try Zip.extract(json, from: data), kind: hint, onlyState: onlyState)
            }
            throw ReferenceImportError.unreadable("The zip file has no .shp, .kml or .geojson file in it.")
        }
        if lower.hasSuffix(".kml") || data.prefix(200).range(of: Data("<kml".utf8)) != nil {
            return KMLReader.features(data, kind: hint, onlyState: onlyState)
        }
        if lower.hasSuffix(".shp") {
            return try Shapefile.features(data, records: [], kind: hint, onlyState: onlyState)
        }
        return try GeoJSON.features(data, kind: hint, onlyState: onlyState)
    }

    /** Census file names say what they hold: cb_2024_us_state_500k, tl_2025_us_county, …_prisecroads. */
    static func hintFromName(_ name: String) -> ReferenceKind? {
        if name.contains("_state") || name.contains("state_") || name.hasPrefix("states") { return .states }
        if name.contains("_county") || name.contains("county_") || name.hasPrefix("counties") { return .counties }
        return nil
    }

    /** A feature's kind from its attributes: RTTYP (route type) or MTFCC (feature class), else the fallback. */
    static func kind(attributes: [String: String], fallback: ReferenceKind?) -> ReferenceKind? {
        func value(_ key: String) -> String? {
            attributes.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value.trimmingCharacters(in: .whitespaces)
        }
        if let route = value("RTTYP")?.uppercased(), !route.isEmpty {
            switch route {
            case "I": return .interstates
            case "U": return .usHighways
            case "S": return .stateRoads
            case "C": return .countyRoads
            default: break
            }
        }
        switch value("MTFCC")?.uppercased() {
        case "G4000": return .states
        case "G4020": return .counties
        case "S1100": return fallback?.isRoad == true ? fallback : .interstates
        default: break
        }
        if let fallback, fallback.isRoad, value("RTTYP") != nil { return nil } // local streets and common names
        return fallback
    }

    /** A feature's name: "Will County" (NAMELSAD), a road's full name, or NAME. */
    static func name(_ attributes: [String: String]) -> String? {
        for key in ["NAMELSAD", "FULLNAME", "NAME", "name", "Name"] {
            if let value = attributes.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value,
               !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
        }
        return nil
    }

    static func stateMatches(_ attributes: [String: String], _ fips: String?) -> Bool {
        guard let fips else { return true }
        let code = attributes.first { $0.key.caseInsensitiveCompare("STATEFP") == .orderedSame }?.value
        return code == nil || code == fips
    }
}

/** Just enough of the zip format to read the files in a Census download or a KMZ. */
enum Zip {
    struct Entry { let name: String; let method: Int; let compressed: Int; let size: Int; let offset: Int }

    static func entries(_ data: Data) throws -> [Entry] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var end = -1
        var i = b.count - 22
        while i >= max(0, b.count - 65_557) {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw ReferenceImportError.unreadable("The zip file is damaged.") }
        let count = u16(end + 10)
        var offset = u32(end + 16)
        var out: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= b.count, u32(offset) == 0x0201_4B50 else { break }
            let method = u16(offset + 10), compressed = u32(offset + 20), size = u32(offset + 24)
            let nameLength = u16(offset + 28), extra = u16(offset + 30), comment = u16(offset + 32)
            let local = u32(offset + 42)
            let name = String(decoding: b[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            out.append(Entry(name: name, method: method, compressed: compressed, size: size, offset: local))
            offset += 46 + nameLength + extra + comment
        }
        return out
    }

    static func extract(_ entry: Entry, from data: Data) throws -> Data {
        let b = data
        func u16(_ o: Int) -> Int { Int(b[b.startIndex + o]) | Int(b[b.startIndex + o + 1]) << 8 }
        let start = entry.offset + 30 + u16(entry.offset + 26) + u16(entry.offset + 28)
        guard start + entry.compressed <= b.count else { throw ReferenceImportError.unreadable("The zip file is damaged.") }
        let body = b.subdata(in: (b.startIndex + start)..<(b.startIndex + start + entry.compressed))
        if entry.method == 0 { return body }
        guard entry.method == 8 else { throw ReferenceImportError.unreadable("The zip file uses an unsupported compression method.") }
        var out = Data(count: entry.size)
        let written = out.withUnsafeMutableBytes { dst in
            body.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, entry.compressed, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == entry.size else { throw ReferenceImportError.unreadable("Couldn't unpack \(entry.name).") }
        return out
    }
}

/** dBASE attribute table that comes with a shapefile. */
enum DBF {
    static func records(_ data: Data) throws -> [[String: String]] {
        let b = [UInt8](data)
        guard b.count > 32 else { return [] }
        let count = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
        let headerLength = Int(b[8]) | Int(b[9]) << 8
        let recordLength = Int(b[10]) | Int(b[11]) << 8
        var fields: [(name: String, offset: Int, length: Int)] = []
        var position = 32, fieldOffset = 1
        while position + 32 <= b.count, b[position] != 0x0D {
            let raw = b[position..<(position + 11)].prefix { $0 != 0 }
            let length = Int(b[position + 16])
            fields.append((String(decoding: raw, as: UTF8.self), fieldOffset, length))
            fieldOffset += length
            position += 32
        }
        let wanted = fields.filter { ["RTTYP", "MTFCC", "STATEFP", "NAME", "FULLNAME", "NAMELSAD"].contains($0.name.uppercased()) }
        var out: [[String: String]] = []
        out.reserveCapacity(count)
        for r in 0..<count {
            let start = headerLength + r * recordLength
            guard start + recordLength <= b.count else { break }
            var record: [String: String] = [:]
            for field in wanted {
                let slice = b[(start + field.offset)..<(start + field.offset + field.length)]
                record[field.name.uppercased()] = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            }
            out.append(record)
        }
        return out
    }
}

/** ESRI shapefile polylines and polygons (including Z and M variants). */
enum Shapefile {
    static func features(_ data: Data, records: [[String: String]], kind: ReferenceKind?, onlyState: String?) throws -> [ReferenceFeature] {
        let b = [UInt8](data)
        guard b.count >= 100 else { throw ReferenceImportError.unreadable("The shapefile is empty.") }
        func be32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        func le32(_ o: Int) -> Int { Int(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)) }
        func f64(_ o: Int) -> Double {
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(b[o + k]) << (8 * k) }
            return Double(bitPattern: bits)
        }
        var out: [ReferenceFeature] = []
        var offset = 100, recordIndex = 0
        while offset + 12 <= b.count {
            let length = be32(offset + 4) * 2
            let content = offset + 8
            defer { offset = content + length; recordIndex += 1 }
            guard content + length <= b.count, length >= 44 else { continue }
            let type = le32(content)
            guard [3, 5, 13, 15, 23, 25].contains(type) else { continue }
            let attributes = recordIndex < records.count ? records[recordIndex] : [:]
            guard ReferenceParser.stateMatches(attributes, onlyState),
                  let featureKind = ReferenceParser.kind(attributes: attributes, fallback: kind) else { continue }
            let partCount = le32(content + 36), pointCount = le32(content + 40)
            let partsAt = content + 44, pointsAt = partsAt + partCount * 4
            guard partCount > 0, pointCount > 0, pointsAt + pointCount * 16 <= content + length else { continue }
            var parts: [[Float]] = []
            for p in 0..<partCount {
                let first = le32(partsAt + p * 4)
                let last = p + 1 < partCount ? le32(partsAt + (p + 1) * 4) : pointCount
                guard first >= 0, last <= pointCount, last > first else { continue }
                var part: [Float] = []
                part.reserveCapacity((last - first) * 2)
                for i in first..<last {
                    part.append(Float(f64(pointsAt + i * 16)))
                    part.append(Float(f64(pointsAt + i * 16 + 8)))
                }
                parts.append(part)
            }
            let closed = type == 5 || type == 15 || type == 25
            if let f = ReferenceFeature(kind: featureKind, closed: closed, parts: parts, name: ReferenceParser.name(attributes)) { out.append(f) }
        }
        return out
    }
}

/** GeoJSON lines and polygons. */
enum GeoJSON {
    static func features(_ data: Data, kind: ReferenceKind?, onlyState: String?) throws -> [ReferenceFeature] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReferenceImportError.unreadable("The file isn't a shapefile zip, GeoJSON or KML file.")
        }
        let items: [[String: Any]]
        if let list = root["features"] as? [[String: Any]] { items = list } else { items = [root] }
        var out: [ReferenceFeature] = []
        for item in items {
            let geometry = item["geometry"] as? [String: Any] ?? item
            var attributes: [String: String] = [:]
            for (key, value) in item["properties"] as? [String: Any] ?? [:] { attributes[key] = "\(value)" }
            guard ReferenceParser.stateMatches(attributes, onlyState),
                  let featureKind = ReferenceParser.kind(attributes: attributes, fallback: kind) else { continue }
            func ring(_ any: Any?) -> [Float] {
                ((any as? [[Any]]) ?? []).flatMap { point -> [Float] in
                    guard point.count >= 2, let lon = (point[0] as? NSNumber)?.floatValue, let lat = (point[1] as? NSNumber)?.floatValue else { return [] }
                    return [lon, lat]
                }
            }
            let coordinates = geometry["coordinates"]
            var parts: [[Float]] = []
            var closed = false
            switch geometry["type"] as? String {
            case "LineString": parts = [ring(coordinates)]
            case "MultiLineString": parts = ((coordinates as? [Any]) ?? []).map(ring)
            case "Polygon": parts = ((coordinates as? [Any]) ?? []).map(ring); closed = true
            case "MultiPolygon":
                for polygon in (coordinates as? [Any]) ?? [] { parts += ((polygon as? [Any]) ?? []).map(ring) }
                closed = true
            default: continue
            }
            if let f = ReferenceFeature(kind: featureKind, closed: closed, parts: parts, name: ReferenceParser.name(attributes)) { out.append(f) }
        }
        return out
    }
}

/** KML placemarks with LineString or Polygon geometry, and their SimpleData/Data attributes. */
final class KMLReader: NSObject, XMLParserDelegate {
    private let fallback: ReferenceKind?
    private let onlyState: String?
    private var out: [ReferenceFeature] = []
    private var attributes: [String: String] = [:]
    private var parts: [[Float]] = []
    private var closed = false
    private var text = ""
    private var dataName: String?
    private var inPlacemark = false

    private init(kind: ReferenceKind?, onlyState: String?) {
        fallback = kind
        self.onlyState = onlyState
    }

    static func features(_ data: Data, kind: ReferenceKind?, onlyState: String?) -> [ReferenceFeature] {
        let reader = KMLReader(kind: kind, onlyState: onlyState)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.out
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "Placemark": inPlacemark = true; self.attributes = [:]; parts = []; closed = false
        case "SimpleData", "Data": dataName = attributes["name"]
        case "Polygon": closed = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "SimpleData", "value":
            if let dataName { attributes[dataName] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if name == "SimpleData" { dataName = nil }
        case "Data": dataName = nil
        case "coordinates" where inPlacemark:
            var part: [Float] = []
            for tuple in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }) {
                let values = tuple.split(separator: ",")
                if values.count >= 2, let lon = Float(values[0]), let lat = Float(values[1]) { part += [lon, lat] }
            }
            parts.append(part)
        case "name" where inPlacemark && dataName == nil:
            if attributes["name"] == nil { attributes["name"] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "Placemark":
            inPlacemark = false
            if ReferenceParser.stateMatches(attributes, onlyState),
               let kind = ReferenceParser.kind(attributes: attributes, fallback: fallback),
               let f = ReferenceFeature(kind: kind, closed: closed, parts: parts, name: ReferenceParser.name(attributes)) { out.append(f) }
        default: break
        }
        text = ""
    }
}

/** US states and their FIPS codes, for downloads. */
struct USState: Identifiable, Hashable {
    let fips: String
    let name: String
    var id: String { fips }

    static let all: [USState] = [
        ("01", "Alabama"), ("02", "Alaska"), ("04", "Arizona"), ("05", "Arkansas"), ("06", "California"), ("08", "Colorado"),
        ("09", "Connecticut"), ("10", "Delaware"), ("11", "District of Columbia"), ("12", "Florida"), ("13", "Georgia"),
        ("15", "Hawaii"), ("16", "Idaho"), ("17", "Illinois"), ("18", "Indiana"), ("19", "Iowa"), ("20", "Kansas"),
        ("21", "Kentucky"), ("22", "Louisiana"), ("23", "Maine"), ("24", "Maryland"), ("25", "Massachusetts"),
        ("26", "Michigan"), ("27", "Minnesota"), ("28", "Mississippi"), ("29", "Missouri"), ("30", "Montana"),
        ("31", "Nebraska"), ("32", "Nevada"), ("33", "New Hampshire"), ("34", "New Jersey"), ("35", "New Mexico"),
        ("36", "New York"), ("37", "North Carolina"), ("38", "North Dakota"), ("39", "Ohio"), ("40", "Oklahoma"),
        ("41", "Oregon"), ("42", "Pennsylvania"), ("44", "Rhode Island"), ("45", "South Carolina"), ("46", "South Dakota"),
        ("47", "Tennessee"), ("48", "Texas"), ("49", "Utah"), ("50", "Vermont"), ("51", "Virginia"), ("53", "Washington"),
        ("54", "West Virginia"), ("55", "Wisconsin"), ("56", "Wyoming"), ("72", "Puerto Rico"),
    ].map { USState(fips: $0.0, name: $0.1) }
}

// MARK: - Settings UI

/** The boundary and road switches, for the map's Layers menu. */
struct ReferenceLayerToggles: View {
    @AppStorage("ref_states") private var states = true
    @AppStorage("ref_counties") private var counties = true
    @AppStorage("ref_interstates") private var interstates = true
    @AppStorage("ref_usHighways") private var usHighways = true
    @AppStorage("ref_stateRoads") private var stateRoads = false
    @AppStorage("ref_countyRoads") private var countyRoads = false

    var body: some View {
        Toggle(ReferenceKind.states.title, isOn: $states)
        Toggle(ReferenceKind.counties.title, isOn: $counties)
        Toggle(ReferenceKind.interstates.title, isOn: $interstates)
        Toggle(ReferenceKind.usHighways.title, isOn: $usHighways)
        Toggle(ReferenceKind.stateRoads.title, isOn: $stateRoads)
        Toggle(ReferenceKind.countyRoads.title, isOn: $countyRoads)
    }
}

/** Setup: boundaries and roads, with importing and downloading for offline use. */
struct ReferenceLayersSection: View {
    @ObservedObject private var store = ReferenceStore.shared
    @AppStorage("refSource") private var source: String = ReferenceSource.online.rawValue
    @AppStorage("refDownloadState") private var downloadState = "17"
    @State private var importKind = "auto"
    @State private var importing = false
    @State private var problem: String?

    var body: some View {
        Section {
            ReferenceLayerToggles()
            Picker("Draw from", selection: $source) {
                ForEach(ReferenceSource.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
        } header: {
            Text("Boundaries and roads")
        } footer: {
            Text("Online lines come from the U.S. Census Bureau's TIGERweb service and are kept for offline use once seen. Interstates are red, US and state routes orange, and county highways gray; boundaries are purple. To see the state, county, township, town and nearby roads at a spot, right-click the map (Mac) or press and hold it (iPhone and iPad).")
        }
        Section {
            Picker("Import as", selection: $importKind) {
                Text("Automatic (from the file)").tag("auto")
                ForEach(ReferenceKind.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Button("Import boundary or road file…") { importing = true }
                .disabled(store.busy != nil)
                .fileImporter(isPresented: $importing,
                              allowedContentTypes: [.zip, .json, UTType(filenameExtension: "geojson") ?? .json,
                                                    UTType(filenameExtension: "kml") ?? .xml, UTType(filenameExtension: "kmz") ?? .zip,
                                                    UTType(filenameExtension: "shp") ?? .data],
                              allowsMultipleSelection: true) { result in
                    guard case let .success(urls) = result else { return }
                    let kind = ReferenceKind(rawValue: importKind)
                    problem = nil
                    Task { @MainActor in
                        for url in urls {
                            do { try await store.importFile(url, as: kind) } catch { problem = "\(url.lastPathComponent): \(error.localizedDescription)" }
                        }
                    }
                }
            HStack {
                Picker("Download for offline use", selection: $downloadState) {
                    ForEach(USState.all) { Text($0.name).tag($0.fips) }
                }
                Button("Download") {
                    guard let state = USState.all.first(where: { $0.fips == downloadState }) else { return }
                    problem = nil
                    Task { @MainActor in
                        do { try await store.downloadState(state) } catch { problem = error.localizedDescription }
                    }
                }
                .disabled(store.busy != nil)
            }
            if let busy = store.busy {
                HStack { ProgressView().controlSize(.small); Text(busy).font(.caption) }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            ForEach(store.files) { file in
                HStack {
                    Toggle(isOn: Binding(get: { file.visible }, set: { store.setVisible(file.id, $0) })) {
                        VStack(alignment: .leading) {
                            Text(file.name)
                            Text(file.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button { store.remove(file.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove \(file.name)")
                }
            }
        } header: {
            Text("Imported boundaries and roads")
        } footer: {
            Text("Import Census TIGER/Line or cartographic boundary shapefiles (.zip), GeoJSON, or KML/KMZ in latitude/longitude. “Automatic” sorts roads by their route type (RTTYP: Interstate, US, State, County) and boundaries by feature class or file name. Download fetches a state's roads (Interstates, US, state and county highways) and county lines, plus the national state lines, from census.gov — about 5–25 MB per state. Set “Draw from” to Imported files or Both to use them. Imported files also name the county, state and roads when you look up a spot offline; files imported before this version need importing again for names.")
        }

    }
}
