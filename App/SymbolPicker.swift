import SwiftUI

/** Names for every symbol in the APRS primary (/) and alternate (\) tables. */
enum AprsSymbolNames {
    static let primary: [Character: String] = [
        "!": "Police/Sheriff", "#": "Digipeater", "$": "Phone", "%": "DX cluster", "&": "HF gateway",
        "'": "Small aircraft", "(": "Mobile satellite station", ")": "Wheelchair", "*": "Snowmobile", "+": "Red Cross",
        ",": "Boy Scouts", "-": "House", ".": "X", "/": "Red dot", "0": "Circle 0", "1": "Circle 1", "2": "Circle 2",
        "3": "Circle 3", "4": "Circle 4", "5": "Circle 5", "6": "Circle 6", "7": "Circle 7", "8": "Circle 8", "9": "Circle 9",
        ":": "Fire", ";": "Campground", "<": "Motorcycle", "=": "Railroad engine", ">": "Car", "?": "File server",
        "@": "Hurricane prediction", "A": "Aid station", "B": "BBS", "C": "Canoe", "E": "Eyeball event", "F": "Tractor",
        "G": "Grid square", "H": "Hotel", "I": "TCP/IP", "K": "School", "L": "PC user", "M": "MacAPRS", "N": "NTS station",
        "O": "Balloon", "P": "Police", "R": "RV", "S": "Space shuttle", "T": "SSTV", "U": "Bus", "V": "ATV",
        "W": "NWS site", "X": "Helicopter", "Y": "Sailboat", "Z": "WinAPRS", "[": "Person", "\\": "DF station",
        "]": "Post office", "^": "Large aircraft", "_": "Weather station", "`": "Dish antenna", "a": "Ambulance",
        "b": "Bicycle", "c": "Command post", "d": "Fire department", "e": "Horse", "f": "Fire truck", "g": "Glider",
        "h": "Hospital", "i": "IOTA", "j": "Jeep", "k": "Truck", "l": "Laptop", "m": "Mic-E repeater", "n": "Node",
        "o": "EOC", "p": "Rover (dog)", "q": "Grid square (128 m)", "r": "Repeater", "s": "Power boat", "t": "Truck stop",
        "u": "Semi truck", "v": "Van", "w": "Water station", "x": "xAPRS (Unix)", "y": "Yagi at QTH",
    ]
    static let alternate: [Character: String] = [
        "!": "Emergency", "#": "Digipeater (overlay)", "$": "Bank or ATM", "%": "Power plant", "&": "Gateway (overlay)",
        "'": "Crash site", "(": "Cloudy", ")": "Firenet", "*": "Snow", "+": "Church", ",": "Girl Scouts", "-": "House (HF)",
        ".": "Ambiguous position", "/": "Waypoint", "0": "Circle (IRLP/EchoLink/WIRES)", "8": "Network node (802.11)",
        "9": "Gas station", ":": "Hail", ";": "Park/picnic", "<": "Advisory", "=": "APRStt (DTMF)", ">": "Car (overlay)",
        "?": "Info kiosk", "@": "Hurricane/tropical storm", "A": "Box (DTMF/RFID)", "B": "Blowing snow", "C": "Coast Guard",
        "D": "Drizzle", "E": "Smoke", "F": "Freezing rain", "G": "Snow shower", "H": "Haze", "I": "Rain shower",
        "J": "Lightning", "K": "Kenwood HT", "L": "Lighthouse", "M": "MARS", "N": "Navigation buoy", "O": "Rocket",
        "P": "Parking", "Q": "Earthquake", "R": "Restaurant", "S": "Satellite", "T": "Thunderstorm", "U": "Sunny",
        "V": "VORTAC", "W": "NWS site (overlay)", "X": "Pharmacy", "Y": "Radio/device", "[": "Wall cloud",
        "^": "Aircraft (overlay)", "_": "Weather site (overlay)", "`": "Rain", "a": "ARES/RACES", "b": "Blowing dust/sand",
        "c": "Civil defense", "d": "DX spot", "e": "Sleet", "f": "Funnel cloud", "g": "Gale flags", "h": "Store",
        "i": "Point of interest", "j": "Work zone", "k": "SUV", "l": "Area", "m": "Value signpost", "n": "Triangle (overlay)",
        "o": "Small circle", "p": "Partly cloudy", "r": "Restrooms", "s": "Boat (overlay)", "t": "Tornado",
        "u": "Truck (overlay)", "v": "Van (overlay)", "w": "Flooding", "x": "Wreck/obstruction", "y": "Skywarn",
        "z": "Shelter", "{": "Fog",
    ]

    static func name(table: String, symbol: Character) -> String? {
        table == "/" ? primary[symbol] : alternate[symbol]
    }
}

/** Every APRS symbol from both tables, with an optional overlay character on the alternate table. */
struct SymbolPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var table = "/"
    @State private var overlay = ""
    @State private var search = ""

    private var symbols: [Character] {
        let chars = (33...126).compactMap { UnicodeScalar($0).map(Character.init) }.filter { $0 != "|" && $0 != "~" }
        let names = table == "/" ? AprsSymbolNames.primary : AprsSymbolNames.alternate
        return chars.filter { c in
            guard let name = names[c] else { return false }
            return search.isEmpty || name.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("Table", selection: $table) {
                    Text("Primary ( / )").tag("/")
                    Text("Alternate ( \\ )").tag("\\")
                }
                .pickerStyle(.segmented)
                if table == "\\" {
                    Picker("Overlay", selection: $overlay) {
                        Text("No overlay").tag("")
                        ForEach(Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init), id: \.self) { Text($0).tag($0) }
                    }
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(symbols, id: \.self) { symbol in
                            let key = (table == "\\" && !overlay.isEmpty ? overlay : table) + String(symbol)
                            let info = AprsSymbol.info(table: table == "\\" && !overlay.isEmpty ? overlay : table, symbol: String(symbol))
                            Button {
                                selection = key
                                dismiss()
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: info.image).font(.title3)
                                    Text(AprsSymbolNames.name(table: table, symbol: symbol) ?? info.name)
                                        .font(.caption).multilineTextAlignment(.center).lineLimit(2)
                                    Text(key).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 70)
                                .padding(4)
                                .background(selection == key ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("Symbol")
            .searchable(text: $search, prompt: "Symbol name")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                let first = String(selection.prefix(1))
                table = first == "/" ? "/" : "\\"
                overlay = (first != "/" && first != "\\") ? first : ""
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
    }
}
