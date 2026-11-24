import AprsCore
import CoreLocation
import SwiftUI

/** Readable names and SF Symbols for the APRS symbols people meet most often. */
enum AprsSymbol {
    struct Info {
        let name: String
        let image: String
    }

    private static let primary: [Character: Info] = [
        "!": Info(name: "Police", image: "shield.fill"),
        "#": Info(name: "Digipeater", image: "dot.radiowaves.left.and.right"),
        "$": Info(name: "Phone", image: "phone.fill"),
        "&": Info(name: "HF gateway", image: "network"),
        "'": Info(name: "Small aircraft", image: "airplane"),
        "+": Info(name: "Red Cross", image: "cross.fill"),
        "-": Info(name: "House", image: "house.fill"),
        ":": Info(name: "Fire", image: "flame.fill"),
        ";": Info(name: "Campground", image: "tent.fill"),
        "<": Info(name: "Motorcycle", image: "bicycle"),
        "=": Info(name: "Railroad engine", image: "train.side.front.car"),
        ">": Info(name: "Car", image: "car.fill"),
        "A": Info(name: "Aid station", image: "cross.case.fill"),
        "B": Info(name: "BBS", image: "server.rack"),
        "C": Info(name: "Canoe", image: "figure.water.fitness"),
        "E": Info(name: "Eyeball event", image: "eye.fill"),
        "F": Info(name: "Tractor", image: "car.fill"),
        "H": Info(name: "Hotel", image: "bed.double.fill"),
        "I": Info(name: "TCP/IP", image: "network"),
        "K": Info(name: "School", image: "graduationcap.fill"),
        "N": Info(name: "NTS station", image: "envelope.fill"),
        "O": Info(name: "Balloon", image: "balloon.fill"),
        "P": Info(name: "Police", image: "shield.fill"),
        "R": Info(name: "RV", image: "bus.doubledecker.fill"),
        "U": Info(name: "Bus", image: "bus.fill"),
        "W": Info(name: "NWS site", image: "cloud.sun.fill"),
        "X": Info(name: "Helicopter", image: "airplane"),
        "Y": Info(name: "Sailboat", image: "sailboat.fill"),
        "[": Info(name: "Person", image: "figure.walk"),
        "^": Info(name: "Large aircraft", image: "airplane"),
        "_": Info(name: "Weather station", image: "cloud.sun.fill"),
        "`": Info(name: "Dish antenna", image: "antenna.radiowaves.left.and.right"),
        "a": Info(name: "Ambulance", image: "cross.case.fill"),
        "b": Info(name: "Bicycle", image: "bicycle"),
        "c": Info(name: "Command post", image: "flag.fill"),
        "d": Info(name: "Fire department", image: "flame.fill"),
        "e": Info(name: "Horse", image: "hare.fill"),
        "f": Info(name: "Fire truck", image: "flame.fill"),
        "h": Info(name: "Hospital", image: "cross.case.fill"),
        "j": Info(name: "Jeep", image: "car.fill"),
        "k": Info(name: "Truck", image: "box.truck.fill"),
        "l": Info(name: "Laptop", image: "laptopcomputer"),
        "n": Info(name: "Node", image: "point.3.connected.trianglepath.dotted"),
        "o": Info(name: "EOC", image: "building.2.fill"),
        "r": Info(name: "Repeater", image: "antenna.radiowaves.left.and.right"),
        "s": Info(name: "Power boat", image: "ferry.fill"),
        "u": Info(name: "Semi truck", image: "truck.box.fill"),
        "v": Info(name: "Van", image: "car.side.fill"),
        "y": Info(name: "Yagi at QTH", image: "house.fill"),
    ]

    private static let alternate: [Character: Info] = [
        "#": Info(name: "Digipeater", image: "dot.radiowaves.left.and.right"),
        "&": Info(name: "Gateway", image: "network"),
        "-": Info(name: "House", image: "house.fill"),
        ">": Info(name: "Car", image: "car.fill"),
        "_": Info(name: "Weather site", image: "cloud.sun.fill"),
        "a": Info(name: "ARES/RACES", image: "cross.fill"),
        "k": Info(name: "SUV", image: "car.fill"),
        "n": Info(name: "Node", image: "point.3.connected.trianglepath.dotted"),
        "r": Info(name: "Restroom", image: "figure.dress.line.vertical.figure"),
        "u": Info(name: "Truck", image: "box.truck.fill"),
        "w": Info(name: "Flooding", image: "water.waves"),
    ]

    static func info(table: String, symbol: String) -> Info {
        guard let code = symbol.first else { return Info(name: "Unknown symbol", image: "mappin") }
        if table == "/" {
            return primary[code] ?? Info(name: AprsSymbolNames.primary[code] ?? "Symbol /\(code)", image: "mappin")
        }
        let overlay = table == "\\" ? "" : " (overlay \(table))"
        if let known = alternate[code] {
            return Info(name: known.name + overlay, image: known.image)
        }
        return Info(name: (AprsSymbolNames.alternate[code] ?? "Symbol \\\(code)") + overlay, image: "mappin")
    }

    /** Symbols offered for your own beacon. */
    static let beaconChoices: [(label: String, table: String, symbol: String)] = [
        ("Car", "/", ">"), ("House", "/", "-"), ("Person", "/", "["), ("Bicycle", "/", "b"),
        ("Truck", "/", "k"), ("Van", "/", "v"), ("RV", "/", "R"), ("Motorcycle", "/", "<"),
        ("Jeep", "/", "j"), ("Semi truck", "/", "u"), ("Sailboat", "/", "Y"), ("Power boat", "/", "s"),
        ("Small aircraft", "/", "'"), ("Laptop", "/", "l"), ("Weather station", "/", "_"),
    ]
}

extension StationDetail {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var symbolInfo: AprsSymbol.Info {
        if kind == "object" || kind == "item", symbolTable == "/" , symbol == "/" {
            return AprsSymbol.Info(name: "Object", image: "flag.fill")
        }
        return AprsSymbol.info(table: symbolTable, symbol: symbol)
    }
    var heardAt: Date { Date(timeIntervalSince1970: Double(heardAtMillis) / 1000) }
    var kindLabel: String {
        switch kind {
        case "weather": return "Weather"
        case "object": return "Object"
        case "item": return "Item"
        default: return "Station"
        }
    }
    var canMessage: Bool { kind != "object" && kind != "item" && AprsProtocol.shared.validCallsign(value: callsign) }
}

enum Units {
    static func distance(_ meters: CLLocationDistance, metric: Bool) -> String {
        if metric { return meters < 1000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1000) }
        let miles = meters / 1609.344
        return miles < 0.1 ? "\(Int(meters * 3.28084)) ft" : String(format: "%.1f mi", miles)
    }
    static func speed(knots: Double, metric: Bool) -> String {
        metric ? String(format: "%.0f km/h", knots * 1.852) : String(format: "%.0f mph", knots * 1.150779)
    }
    static func speed(kph: Double, metric: Bool) -> String {
        metric ? String(format: "%.0f km/h", kph) : String(format: "%.0f mph", kph / 1.609344)
    }
    static func altitude(_ meters: Double, metric: Bool) -> String {
        metric ? String(format: "%.0f m", meters) : String(format: "%.0f ft", meters * 3.28084)
    }
    static func temperature(_ celsius: Double, metric: Bool) -> String {
        metric ? String(format: "%.1f °C", celsius) : String(format: "%.0f °F", celsius * 9 / 5 + 32)
    }
    static func rain(_ mm: Double, metric: Bool) -> String {
        metric ? String(format: "%.1f mm", mm) : String(format: "%.2f in", mm / 25.4)
    }
    static func pressure(_ hpa: Double, metric: Bool) -> String {
        metric ? String(format: "%.1f hPa", hpa) : String(format: "%.2f inHg", hpa * 0.02953)
    }
    static func compass(_ degrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((degrees.truncatingRemainder(dividingBy: 360) + 360 + 11.25) / 22.5) % 16
        return points[index]
    }
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m ago"
    }
}

enum Geo {
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /** Six-character Maidenhead grid locator, e.g. EN51nx. */
    static func grid(_ c: CLLocationCoordinate2D) -> String {
        let lon = min(max(c.longitude + 180, 0), 359.9999), lat = min(max(c.latitude + 90, 0), 179.9999)
        let upper = Array("ABCDEFGHIJKLMNOPQR"), lower = Array("abcdefghijklmnopqrstuvwx")
        let field = "\(upper[Int(lon / 20)])\(upper[Int(lat / 10)])"
        let square = "\(Int(lon.truncatingRemainder(dividingBy: 20) / 2))\(Int(lat.truncatingRemainder(dividingBy: 10)))"
        let sub = "\(lower[Int(lon.truncatingRemainder(dividingBy: 2) * 12)])\(lower[Int(lat.truncatingRemainder(dividingBy: 1) * 24)])"
        return field + square + sub
    }

    static func format(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f°%@, %.5f°%@", abs(c.latitude), c.latitude >= 0 ? "N" : "S",
               abs(c.longitude), c.longitude >= 0 ? "E" : "W")
    }
}
