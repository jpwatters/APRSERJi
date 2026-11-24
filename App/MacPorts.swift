#if os(macOS)
import AprsCore
import CoreBluetooth
import Darwin
import Foundation
import IOBluetooth
import SwiftUI

/** A byte link the Mac carries itself: serial, Bluetooth SPP or Bluetooth LE. */
protocol ByteLink: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onState: ((Bool, String?) -> Void)? { get set }
    func open()
    func close()
    func write(_ data: Data)
}

/** A POSIX serial port (USB serial adapters, Kenwood and Mobilinkd TNCs, NMEA GPS receivers, Ultimeter weather stations). */
final class SerialPort: ByteLink {
    let path: String
    let baud: Int
    var onData: ((Data) -> Void)?
    var onState: ((Bool, String?) -> Void)?
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var retry: DispatchWorkItem?
    private var wanted = false

    init(path: String, baud: Int) {
        self.path = path
        self.baud = baud
    }

    /** Serial devices present now, e.g. /dev/cu.usbserial-1410. */
    static func devices() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth-Incoming") }.sorted().map { "/dev/" + $0 }
    }

    func open() {
        wanted = true
        guard fd < 0 else { return }
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            onState?(false, "Cannot open \(path): \(String(cString: strerror(errno)))")
            scheduleRetry()
            return
        }
        var settings = termios()
        tcgetattr(handle, &settings)
        cfmakeraw(&settings)
        cfsetspeed(&settings, speed_t(baud))
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(handle, TCSANOW, &settings)
        fd = handle
        let reader = DispatchSource.makeReadSource(fileDescriptor: handle, queue: .main)
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        reader.setCancelHandler { Darwin.close(handle) }
        reader.resume()
        source = reader
        onState?(true, nil)
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            onData?(Data(buffer[0..<count]))
        } else if count == 0 || (count < 0 && errno != EAGAIN) {
            drop("The serial device closed")
        }
    }

    private func drop(_ reason: String) {
        source?.cancel()
        source = nil
        fd = -1
        onState?(false, reason)
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard wanted else { return }
        retry?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.open() }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    func close() {
        wanted = false
        retry?.cancel()
        source?.cancel()
        source = nil
        fd = -1
    }

    func write(_ data: Data) {
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base + offset, data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }
}

/** Bluetooth Classic serial port profile (TH-D74/D75, many KISS TNCs) over IOBluetooth RFCOMM. */
final class SppLink: NSObject, ByteLink, IOBluetoothRFCOMMChannelDelegate {
    let address: String
    var onData: ((Data) -> Void)?
    var onState: ((Bool, String?) -> Void)?
    private var channel: IOBluetoothRFCOMMChannel?
    private var wanted = false

    init(address: String) { self.address = address }

    static func pairedDevices() -> [(name: String, address: String)] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.map { ($0.name ?? $0.addressString ?? "Device", $0.addressString ?? "") }.filter { !$0.address.isEmpty }
    }

    func open() {
        wanted = true
        guard channel == nil, let device = IOBluetoothDevice(addressString: address) else {
            onState?(false, "Pair the device in System Settings ▸ Bluetooth first")
            return
        }
        var channelID: BluetoothRFCOMMChannelID = 1
        let serialPort = IOBluetoothSDPUUID(uuid16: 0x1101)
        if let record = device.getServiceRecord(for: serialPort) {
            _ = record.getRFCOMMChannelID(&channelID)
        }
        var opened: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
        if result != kIOReturnSuccess {
            onState?(false, "Bluetooth connection failed (\(result))")
            retry()
        } else {
            channel = opened
        }
    }

    private func retry() {
        guard wanted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.wanted, self.channel == nil else { return }
            self.open()
        }
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        if error == kIOReturnSuccess {
            onState?(true, nil)
        } else {
            channel = nil
            onState?(false, "Bluetooth connection failed (\(error))")
            retry()
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        onData?(Data(bytes: dataPointer, count: dataLength))
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        channel = nil
        onState?(false, "Bluetooth link closed")
        retry()
    }

    func close() {
        wanted = false
        channel?.close()
        channel = nil
    }

    func write(_ data: Data) {
        guard let channel else { return }
        let mtu = max(1, Int(channel.getMTU()))
        var offset = 0
        while offset < data.count {
            var chunk = [UInt8](data[offset..<min(data.count, offset + mtu)])
            _ = channel.writeSync(&chunk, length: UInt16(chunk.count))
            offset += chunk.count
        }
    }
}

/** KISS over Bluetooth LE: the BLE KISS service (Mobilinkd TNC3/TNC4, BTECH UV-PRO, many ESP32 TNCs) or Nordic UART. */
final class BleLink: NSObject, ByteLink, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let services = [
        (service: CBUUID(string: "00000001-ba2a-46c9-ae49-01b0961f68bb"), write: CBUUID(string: "00000002-ba2a-46c9-ae49-01b0961f68bb"), notify: CBUUID(string: "00000003-ba2a-46c9-ae49-01b0961f68bb")),
        (service: CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e"), write: CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e"), notify: CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")),
    ]
    let identifier: UUID?
    var onData: ((Data) -> Void)?
    var onState: ((Bool, String?) -> Void)?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var wanted = false

    init(identifier: String) { self.identifier = UUID(uuidString: identifier) }

    func open() {
        wanted = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { connect() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { connect() } else { onState?(false, "Bluetooth is off or not allowed") }
    }

    private func connect() {
        guard wanted, let central, central.state == .poweredOn, let identifier else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            peripheral = known
            known.delegate = self
            central.connect(known)
        } else {
            onState?(false, "Bluetooth LE device not found; choose it again")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(Self.services.map(\.service))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onState?(false, error?.localizedDescription ?? "Connection failed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.connect() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        writeCharacteristic = nil
        onState?(false, "Bluetooth LE link closed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.connect() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            if let match = Self.services.first(where: { $0.service == service.uuid }) {
                peripheral.discoverCharacteristics([match.write, match.notify], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let match = Self.services.first(where: { $0.service == service.uuid }) else { return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == match.notify { peripheral.setNotifyValue(true, for: characteristic) }
            if characteristic.uuid == match.write { writeCharacteristic = characteristic }
        }
        if writeCharacteristic != nil { onState?(true, nil) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let value = characteristic.value, !value.isEmpty { onData?(value) }
    }

    func close() {
        wanted = false
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeCharacteristic = nil
    }

    func write(_ data: Data) {
        guard let peripheral, let writeCharacteristic else { return }
        let type: CBCharacteristicWriteType = writeCharacteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let size = max(20, peripheral.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < data.count {
            peripheral.writeValue(data.subdata(in: offset..<min(data.count, offset + size)), for: writeCharacteristic, type: type)
            offset += size
        }
    }
}

/** Scans for Bluetooth LE KISS TNCs so one can be picked in the port editor. */
final class BleScanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var found: [(name: String, id: String)] = []
    private var central: CBCentralManager?

    func start() {
        found = []
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func stop() { central?.stopScan() }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { central.scanForPeripherals(withServices: BleLink.services.map(\.service)) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier.uuidString
        if !found.contains(where: { $0.id == id }) {
            found.append((peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "TNC", id))
        }
    }
}

struct BlePicker: View {
    @Binding var selection: String
    @StateObject private var scanner = BleScanner()

    var body: some View {
        Picker("Device", selection: $selection) {
            Text(selection.isEmpty ? "Scanning…" : "Saved device").tag(selection)
            ForEach(scanner.found, id: \.id) { Text($0.name).tag($0.id) }
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }
}

/** Opens serial and Bluetooth links for the engine's external ports and moves bytes both ways. */
@MainActor
final class ExternalPorts {
    static let shared = ExternalPorts()
    private var links: [String: (setting: PortSetting, link: ByteLink)] = [:]
    private var timer: Timer?
    private weak var core: AppleAprs?

    func update(_ ports: [PortSetting], core: AppleAprs) {
        self.core = core
        let wanted = Dictionary(uniqueKeysWithValues: ports.map { ($0.id, $0) })
        for (id, entry) in links where wanted[id] != entry.setting {
            entry.link.close()
            links[id] = nil
        }
        for port in ports where links[port.id] == nil && !port.device.isEmpty {
            let link: ByteLink
            switch port.transport {
            case .serial: link = SerialPort(path: port.device, baud: port.baud)
            case .spp: link = SppLink(address: port.device)
            case .ble: link = BleLink(identifier: port.device)
            case .tcp: continue
            }
            let id = port.id
            link.onData = { [weak self] data in
                guard let core = self?.core else { return }
                Task { try? await core.externalReceivedData(id: id, data: data) }
            }
            link.onState = { [weak self, weak link] connected, error in
                guard let self, let core = self.core else { return }
                core.externalLinkState(id: id, connected: connected, error: error)
                if connected, let link {
                    if !port.initCommands.isEmpty, let commands = port.initCommands.data(using: .ascii) { link.write(commands) }
                    for bytes in core.externalOpeningData(id: id) { link.write(bytes) }
                }
            }
            links[port.id] = (port, link)
            link.open()
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pump() }
            }
        }
    }

    private func pump() {
        guard let core else { return }
        for (id, entry) in links {
            var count = 0
            while count < 16, let data = core.externalTakeOutgoingData(id: id) {
                entry.link.write(data)
                count += 1
            }
        }
    }
}
#endif
