# SmartShoeBLE

An iOS Swift module for connecting to BLE shoes or insole sensors, publishing live telemetry, and displaying a SwiftUI pressure dashboard. The implementation is in [SmartShoeBLE.swift](SmartShoeBLE.swift).

## Integration

Add `SmartShoeBLE.swift` to an iOS app target that links CoreBluetooth, SwiftUI, and Combine. The dashboard uses `NavigationStack` and requires iOS 16 or later. Add `NSBluetoothAlwaysUsageDescription` to the app target's `Info.plist`, with a user-facing explanation of why the app uses Bluetooth. The containing app is responsible for this permission declaration.

Use `ShoeDashboardView()` as a screen, or create a `ShoeViewModel` and observe its connection status and telemetry. The central manager starts reconnecting to its saved peripheral identifier when Bluetooth becomes available. A first launch with no saved shoe waits for the user to scan.

```swift
let configuration = ShoeBLEConfiguration(
    serviceUUID: CBUUID(string: "YOUR-SERVICE-UUID"),
    heelPressureUUID: CBUUID(string: "YOUR-HEEL-UUID"),
    forefootLeftPressureUUID: CBUUID(string: "YOUR-LEFT-UUID"),
    forefootRightPressureUUID: CBUUID(string: "YOUR-RIGHT-UUID"),
    cadenceUUID: CBUUID(string: "YOUR-CADENCE-UUID"),
    pressureEncoding: .unsigned16LittleEndian
)
let model = ShoeViewModel(manager: ShoeBLEManager(configuration: configuration))
```

## Sensor Protocol

The default service UUID is `180D`; this is the standard Heart Rate service UUID and is only suitable when the shoe advertises it. Pressure characteristic UUIDs `A001`–`A003` and cadence UUID `A004` are placeholders; configure the values published by your hardware. Battery uses the standard `2A19` characteristic.

Pressure notifications are decoded per characteristic as unsigned 8-bit, unsigned 16-bit little-endian, or IEEE-754 32-bit little-endian float according to `pressureEncoding`. Integer values are normalized across their full representable range; float values are clamped to `0...1`. Cadence is an unsigned integer in steps per minute (8-bit or 16-bit little-endian). Confirm byte order, scale, units, and packet framing against the shoe vendor's protocol before shipping. This implementation expects one sensor reading per characteristic value; it does not reassemble fragmented application-level packets.

Ground impact is shown as relative load by default. Set `newtonsPerSensorAtFullScale` only with a vendor-supported calibration; the resulting value is a calibrated estimate, not a substitute for validated measurement.