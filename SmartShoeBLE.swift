import Combine
import CoreBluetooth
import SwiftUI
import UIKit

// MARK: - Configuration

public enum ShoePressureEncoding {
    case unsigned8
    case unsigned16LittleEndian
    case float32LittleEndian
}

public struct ShoeBLEConfiguration {
    public var serviceUUID: CBUUID
    public var heelPressureUUID: CBUUID
    public var forefootLeftPressureUUID: CBUUID
    public var forefootRightPressureUUID: CBUUID
    public var cadenceUUID: CBUUID?
    public var batteryLevelUUID: CBUUID
    public var pressureEncoding: ShoePressureEncoding
    public var newtonsPerSensorAtFullScale: Double?

    public init(
        serviceUUID: CBUUID = CBUUID(string: "180D"),
        heelPressureUUID: CBUUID = CBUUID(string: "A001"),
        forefootLeftPressureUUID: CBUUID = CBUUID(string: "A002"),
        forefootRightPressureUUID: CBUUID = CBUUID(string: "A003"),
        cadenceUUID: CBUUID? = CBUUID(string: "A004"),
        batteryLevelUUID: CBUUID = CBUUID(string: "2A19"),
        pressureEncoding: ShoePressureEncoding = .unsigned16LittleEndian,
        newtonsPerSensorAtFullScale: Double? = nil
    ) {
        self.serviceUUID = serviceUUID
        self.heelPressureUUID = heelPressureUUID
        self.forefootLeftPressureUUID = forefootLeftPressureUUID
        self.forefootRightPressureUUID = forefootRightPressureUUID
        self.cadenceUUID = cadenceUUID
        self.batteryLevelUUID = batteryLevelUUID
        self.pressureEncoding = pressureEncoding
        self.newtonsPerSensorAtFullScale = newtonsPerSensorAtFullScale
    }

    fileprivate var pressureCharacteristics: [CBUUID] {
        [heelPressureUUID, forefootLeftPressureUUID, forefootRightPressureUUID]
    }

    fileprivate var allCharacteristics: [CBUUID] {
        pressureCharacteristics + [batteryLevelUUID] + (cadenceUUID.map { [$0] } ?? [])
    }
}

// MARK: - Telemetry

public struct ShoeTelemetry: Equatable {
    public var heelPressure: Float = 0
    public var forefootLeft: Float = 0
    public var forefootRight: Float = 0
    public var cadenceSPM: Double?
    public var batteryLevel: Int?
    public var groundImpactNewtons: Double?

    /// Relative load unless the sensor-specific force scale is configured.
    public var groundImpactRelative: Double {
        (Double(heelPressure) + Double(forefootLeft) + Double(forefootRight)) / 3
    }

    public init() {}
}

public enum ShoeConnectionStatus: String {
    case disconnected = "Disconnected"
    case scanning = "Scanning"
    case connected = "Connected"
}

// MARK: - CoreBluetooth manager

/// Own for the lifetime of the connection. Delegate callbacks use the main queue.
public final class ShoeBLEManager: NSObject, ObservableObject {
    @Published public private(set) var connectionStatus: ShoeConnectionStatus = .disconnected
    @Published public private(set) var telemetry = ShoeTelemetry()
    @Published public private(set) var statusMessage = "Ready to scan"

    private let configuration: ShoeBLEConfiguration
    private let savedPeripheralKey = "SmartShoeBLE.savedPeripheralIdentifier"
    private var central: CBCentralManager!
    private var activePeripheral: CBPeripheral?
    private var wantsConnection = false
    private var targetPeripheralIdentifier: UUID?

    public init(configuration: ShoeBLEConfiguration = ShoeBLEConfiguration()) {
        self.configuration = configuration
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Scans for a configured service and connects to the first matching shoe.
    public func startScanning() {
        wantsConnection = true
        targetPeripheralIdentifier = nil
        guard central.state == .poweredOn else {
            connectionStatus = .disconnected
            statusMessage = "Bluetooth is not available"
            return
        }
        beginServiceScan(message: "Looking for shoes…")
    }

    /// Stops an active scan or connection attempt without forgetting the shoe.
    public func stopScanning() {
        wantsConnection = false
        targetPeripheralIdentifier = nil
        central.stopScan()

        if let peripheral = activePeripheral {
            central.cancelPeripheralConnection(peripheral)
            connectionStatus = .disconnected
            statusMessage = "Disconnecting…"
        } else {
            connectionStatus = .disconnected
            statusMessage = "Scan stopped"
        }
        resetTelemetry()
    }

    /// Disconnects and clears the saved peripheral identifier.
    public func disconnect() {
        stopScanning()
        UserDefaults.standard.removeObject(forKey: savedPeripheralKey)
        if activePeripheral == nil {
            statusMessage = "Disconnected"
        }
    }

    private func beginServiceScan(message: String) {
        guard wantsConnection, central.state == .poweredOn else { return }
        central.stopScan()
        activePeripheral = nil
        connectionStatus = .scanning
        statusMessage = message
        central.scanForPeripherals(
            withServices: [configuration.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func reconnectToSavedPeripheral() {
        guard central.state == .poweredOn else { return }
        guard
            let value = UserDefaults.standard.string(forKey: savedPeripheralKey),
            let identifier = UUID(uuidString: value)
        else {
            targetPeripheralIdentifier = nil
            beginServiceScan(message: "Looking for shoes…")
            return
        }

        wantsConnection = true
        targetPeripheralIdentifier = identifier
        connectionStatus = .scanning
        statusMessage = "Reconnecting…"

        if let peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            connect(to: peripheral)
        } else {
            // Only connect to this identifier; do not silently adopt another shoe.
            beginServiceScan(message: "Searching for saved shoe…")
        }
    }

    private func connect(to peripheral: CBPeripheral) {
        guard wantsConnection else { return }
        guard targetPeripheralIdentifier == nil ||
                targetPeripheralIdentifier == peripheral.identifier else { return }

        central.stopScan()
        activePeripheral = peripheral
        peripheral.delegate = self
        connectionStatus = .scanning
        statusMessage = "Connecting…"
        central.connect(peripheral, options: nil)
    }

    private func resetTelemetry() {
        telemetry = ShoeTelemetry()
    }

    private func updateGroundImpact(in value: inout ShoeTelemetry) {
        guard let scale = configuration.newtonsPerSensorAtFullScale else {
            value.groundImpactNewtons = nil
            return
        }
        value.groundImpactNewtons = (
            Double(value.heelPressure) +
            Double(value.forefootLeft) +
            Double(value.forefootRight)
        ) * scale
    }

    private func normalizedPressure(from data: Data) -> Float? {
        let bytes = [UInt8](data)
        switch configuration.pressureEncoding {
        case .unsigned8:
            guard let raw = bytes.first else { return nil }
            return Float(raw) / Float(UInt8.max)
        case .unsigned16LittleEndian:
            guard bytes.count >= 2 else { return nil }
            let raw = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            return Float(raw) / Float(UInt16.max)
        case .float32LittleEndian:
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) |
                (UInt32(bytes[1]) << 8) |
                (UInt32(bytes[2]) << 16) |
                (UInt32(bytes[3]) << 24)
            let value = Float(bitPattern: bits)
            guard value.isFinite else { return nil }
            return min(1, max(0, value))
        }
    }

    private func cadence(from data: Data) -> Double? {
        guard !data.isEmpty else { return nil }
        if data.count >= 2 {
            return Double(UInt16(data[0]) | (UInt16(data[1]) << 8))
        }
        return Double(data[0])
    }

    private func handleValue(_ characteristic: CBCharacteristic) {
        guard let data = characteristic.value else { return }
        var updated = telemetry

        switch characteristic.uuid {
        case configuration.heelPressureUUID:
            guard let value = normalizedPressure(from: data) else { return }
            updated.heelPressure = value
            updateGroundImpact(in: &updated)
        case configuration.forefootLeftPressureUUID:
            guard let value = normalizedPressure(from: data) else { return }
            updated.forefootLeft = value
            updateGroundImpact(in: &updated)
        case configuration.forefootRightPressureUUID:
            guard let value = normalizedPressure(from: data) else { return }
            updated.forefootRight = value
            updateGroundImpact(in: &updated)
        case configuration.batteryLevelUUID:
            guard let raw = data.first, raw <= 100 else { return }
            updated.batteryLevel = Int(raw)
        default:
            guard characteristic.uuid == configuration.cadenceUUID,
                  let value = cadence(from: data) else { return }
            updated.cadenceSPM = value
        }
        telemetry = updated
    }
}

extension ShoeBLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantsConnection {
                if targetPeripheralIdentifier != nil {
                    beginServiceScan(message: "Searching for saved shoe…")
                } else {
                    beginServiceScan(message: "Looking for shoes…")
                }
            } else if UserDefaults.standard.string(forKey: savedPeripheralKey) != nil {
                wantsConnection = true
                reconnectToSavedPeripheral()
            } else {
                statusMessage = "Ready to scan"
            }
        case .poweredOff:
            activePeripheral = nil
            connectionStatus = .disconnected
            statusMessage = "Bluetooth is turned off"
        case .unauthorized:
            connectionStatus = .disconnected
            statusMessage = "Bluetooth permission is denied"
        case .unsupported:
            connectionStatus = .disconnected
            statusMessage = "Bluetooth LE is not supported"
        case .resetting:
            connectionStatus = .disconnected
            statusMessage = "Bluetooth is resetting"
        case .unknown:
            connectionStatus = .disconnected
            statusMessage = "Bluetooth state is unknown"
        @unknown default:
            connectionStatus = .disconnected
            statusMessage = "Bluetooth is unavailable"
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard wantsConnection else { return }
        connect(to: peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard activePeripheral?.identifier == peripheral.identifier else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard wantsConnection else {
            central.cancelPeripheralConnection(peripheral)
            return
        }

        peripheral.delegate = self
        connectionStatus = .connected
        statusMessage = "Connected; discovering sensors…"
        targetPeripheralIdentifier = peripheral.identifier
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedPeripheralKey)
        peripheral.discoverServices([configuration.serviceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        activePeripheral = nil
        guard wantsConnection else { return }
        statusMessage = "Connection failed; searching again…"
        beginServiceScan(message: statusMessage)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        activePeripheral = nil
        resetTelemetry()

        guard wantsConnection else {
            connectionStatus = .disconnected
            statusMessage = "Disconnected"
            return
        }

        targetPeripheralIdentifier = peripheral.identifier
        statusMessage = "Connection lost; reconnecting…"
        beginServiceScan(message: statusMessage)
    }
}

extension ShoeBLEManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        guard error == nil, let services = peripheral.services else {
            statusMessage = "Could not discover shoe services"
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard services.contains(where: { $0.uuid == configuration.serviceUUID }) else {
            statusMessage = "The shoe service was not found"
            central.cancelPeripheralConnection(peripheral)
            return
        }
        for service in services where service.uuid == configuration.serviceUUID {
            peripheral.discoverCharacteristics(configuration.allCharacteristics, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        guard error == nil, let characteristics = service.characteristics else {
            statusMessage = "Could not discover shoe characteristics"
            return
        }

        let supported = Set(configuration.allCharacteristics)
        for characteristic in characteristics where supported.contains(characteristic.uuid) {
            if characteristic.properties.contains(.notify) ||
                characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }
        statusMessage = "Connected"
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        guard error == nil else {
            statusMessage = "A sensor value could not be read"
            return
        }
        handleValue(characteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard activePeripheral?.identifier == peripheral.identifier, error != nil else { return }
        statusMessage = "Could not subscribe to a sensor"
    }
}

// MARK: - View model

public final class ShoeViewModel: ObservableObject {
    @Published public private(set) var connectionStatus: ShoeConnectionStatus = .disconnected
    @Published public private(set) var telemetry = ShoeTelemetry()
    @Published public private(set) var statusMessage = "Ready to scan"

    public let manager: ShoeBLEManager

    public init(manager: ShoeBLEManager = ShoeBLEManager()) {
        self.manager = manager
        manager.$connectionStatus.assign(to: &$connectionStatus)
        manager.$telemetry.assign(to: &$telemetry)
        manager.$statusMessage.assign(to: &$statusMessage)
    }

    public func scanOrDisconnect() {
        switch connectionStatus {
        case .connected: manager.disconnect()
        case .scanning: manager.stopScanning()
        case .disconnected: manager.startScanning()
        }
    }

    public var connectionButtonTitle: String {
        switch connectionStatus {
        case .connected: "Disconnect"
        case .scanning: "Stop Scan"
        case .disconnected: "Scan for Shoes"
        }
    }

    public var groundImpactValue: String {
        if let force = telemetry.groundImpactNewtons {
            return String(format: "%.0f N", force)
        }
        return String(format: "%.0f%%", telemetry.groundImpactRelative * 100)
    }

    public var groundImpactSubtitle: String {
        telemetry.groundImpactNewtons == nil ? "Relative load" : "Calibrated estimate"
    }
}

// MARK: - Dashboard

public struct ShoeDashboardView: View {
    @StateObject private var viewModel: ShoeViewModel

    public init(viewModel: ShoeViewModel = ShoeViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    connectionHeader

                    SoleHeatMapView(
                        heel: viewModel.telemetry.heelPressure,
                        forefootLeft: viewModel.telemetry.forefootLeft,
                        forefootRight: viewModel.telemetry.forefootRight
                    )
                    .frame(maxWidth: 300)
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 12) {
                        metricCard(
                            title: "Cadence",
                            value: viewModel.telemetry.cadenceSPM.map {
                                String(Int($0.rounded()))
                            } ?? "—",
                            unit: "SPM",
                            subtitle: "Steps per minute"
                        )
                        metricCard(
                            title: "Ground Impact Force",
                            value: viewModel.groundImpactValue,
                            unit: "",
                            subtitle: viewModel.groundImpactSubtitle
                        )
                    }

                    Button(action: viewModel.scanOrDisconnect) {
                        Text(viewModel.connectionButtonTitle)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)

                    Text(viewModel.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("Shoe Monitor")
        }
    }

    private var connectionHeader: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.connectionStatus.rawValue).font(.headline)
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: batterySymbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(viewModel.telemetry.batteryLevel.map { "\($0)%" } ?? "—")
                .font(.subheadline.monospacedDigit())
                .accessibilityLabel("Battery \(viewModel.telemetry.batteryLevel.map { "\($0) percent" } ?? "unknown")")
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusColor: Color {
        switch viewModel.connectionStatus {
        case .connected: .green
        case .scanning: .orange
        case .disconnected: .gray
        }
    }

    private var batterySymbol: String {
        guard let level = viewModel.telemetry.batteryLevel else { return "battery.0" }
        switch level {
        case 76...: "battery.100"
        case 51...: "battery.75"
        case 26...: "battery.50"
        case 1...: "battery.25"
        default: "battery.0"
        }
    }

    private func metricCard(title: String, value: String, unit: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SoleHeatMapView: View {
    let heel: Float
    let forefootLeft: Float
    let forefootRight: Float

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                SoleShape().fill(Color(uiColor: .secondarySystemBackground))
                pressureSpot(forefootLeft, size: CGSize(width: size.width * 0.42, height: size.height * 0.22))
                    .position(x: size.width * 0.36, y: size.height * 0.23)
                pressureSpot(forefootRight, size: CGSize(width: size.width * 0.42, height: size.height * 0.22))
                    .position(x: size.width * 0.64, y: size.height * 0.23)
                pressureSpot(heel, size: CGSize(width: size.width * 0.48, height: size.height * 0.24))
                    .position(x: size.width * 0.50, y: size.height * 0.79)
                SoleShape().stroke(Color.secondary.opacity(0.45), lineWidth: 2)
                VStack {
                    Text("FOREFOOT").font(.caption2.weight(.semibold))
                    Spacer()
                    Text("HEEL").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.primary.opacity(0.65))
                .padding(.vertical, size.height * 0.13)
            }
            .clipShape(SoleShape())
        }
        .aspectRatio(0.68, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Foot pressure. Heel \(Int(heel * 100)) percent, left forefoot \(Int(forefootLeft * 100)) percent, right forefoot \(Int(forefootRight * 100)) percent."
        )
    }

    private func pressureSpot(_ value: Float, size: CGSize) -> some View {
        let color = heatColor(value)
        return Ellipse()
            .fill(RadialGradient(
                colors: [color.opacity(0.95), color.opacity(0.45), color.opacity(0)],
                center: .center,
                startRadius: 1,
                endRadius: max(size.width, size.height) * 0.52
            ))
            .frame(width: size.width, height: size.height)
    }

    private func heatColor(_ value: Float) -> Color {
        let pressure = min(1, max(0, Double(value)))
        if pressure < 0.5 {
            let blend = pressure * 2
            return Color(red: blend, green: 1, blue: 0)
        }
        let blend = (pressure - 0.5) * 2
        return Color(red: 1, green: 1 - blend, blue: 0)
    }
}

private struct SoleShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.50, 0.98))
        path.addCurve(to: point(0.20, 0.79), control1: point(0.31, 1.02), control2: point(0.18, 0.94))
        path.addCurve(to: point(0.15, 0.46), control1: point(0.20, 0.66), control2: point(0.12, 0.58))
        path.addCurve(to: point(0.30, 0.10), control1: point(0.17, 0.30), control2: point(0.20, 0.15))
        path.addCurve(to: point(0.49, 0.12), control1: point(0.37, 0.02), control2: point(0.44, 0.04))
        path.addCurve(to: point(0.70, 0.09), control1: point(0.55, 0.03), control2: point(0.63, 0.01))
        path.addCurve(to: point(0.86, 0.43), control1: point(0.84, 0.10), control2: point(0.89, 0.27))
        path.addCurve(to: point(0.81, 0.66), control1: point(0.83, 0.54), control2: point(0.79, 0.58))
        path.addCurve(to: point(0.65, 0.96), control1: point(0.86, 0.85), control2: point(0.78, 0.98))
        path.addCurve(to: point(0.50, 0.98), control1: point(0.58, 0.95), control2: point(0.54, 0.97))
        path.closeSubpath()
        return path
    }
}