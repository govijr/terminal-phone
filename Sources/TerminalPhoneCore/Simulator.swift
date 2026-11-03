import Foundation
import TerminalMacCore

public struct SimulatorCatalog: Decodable {
    public struct Runtime: Decodable {
        public let identifier: String
        public let name: String
        public let version: String
        public let isAvailable: Bool
    }
    public struct DeviceType: Decodable {
        public let identifier: String
        public let name: String
        public let productFamily: String?
        public let bundlePath: String?
        public let minRuntimeVersion: UInt64?
        public let maxRuntimeVersion: UInt64?
    }
    public struct Device: Decodable {
        public let udid: String
        public let name: String
        public let state: String
        public let isAvailable: Bool?
        public let deviceTypeIdentifier: String?
    }
    public let runtimes: [Runtime]
    public let devicetypes: [DeviceType]
    public let devices: [String: [Device]]

    public func select(device: String?, runtime: String?) throws -> (DeviceType, Runtime) {
        let available = runtimes.filter {
            $0.isAvailable && $0.identifier.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-") &&
            (runtime == nil || [$0.identifier, $0.name, $0.version].contains(runtime!))
        }.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        guard !available.isEmpty else {
            throw Failure("No matching iOS runtime installed. Install one in Xcode → Settings → Components, then run terminal-phone doctor.")
        }
        for os in available {
            let version = Self.packedVersion(os.version)
            let phones = devicetypes.filter {
                ($0.productFamily == "iPhone" || $0.name.hasPrefix("iPhone")) &&
                (device == nil || [$0.name, $0.identifier].contains(device!)) &&
                version >= ($0.minRuntimeVersion ?? 0) && version <= ($0.maxRuntimeVersion ?? UInt64.max)
            }
            if let phone = phones.first { return (phone, os) }
        }
        throw Failure("No compatible iPhone device type found. Run terminal-phone devices and runtimes, then choose --device and --runtime.")
    }

    public static func packedVersion(_ version: String) -> UInt64 {
        let numbers = version.split(separator: ".").compactMap { UInt64($0) }
        return (numbers.first ?? 0) << 16 | (numbers.count > 1 ? numbers[1] : 0) << 8 | (numbers.count > 2 ? numbers[2] : 0)
    }

    public func device(for phone: Phone) throws -> Device {
        // Never address "booted": another agent or Xcode may have a different phone running.
        guard let device = devices[phone.runtime]?.first(where: { $0.udid.caseInsensitiveCompare(phone.udid) == .orderedSame }),
              device.name == phone.simulatorName,
              device.deviceTypeIdentifier == phone.deviceType,
              device.isAvailable != false else {
            throw Failure("The dedicated simulator for '\(phone.name)' is missing, renamed, or unavailable. Its saved UUID is \(phone.udid). Restore its runtime or use a new phone name.")
        }
        return device
    }
}

public struct Phone: Codable {
    public enum Kind: String, Codable { case simulator, device }
    public let name: String
    /// The simulator UUID, or for a real iPhone its CoreDevice identifier (also a UUID).
    public let udid: String
    public let deviceType: String
    public let runtime: String
    /// Absent in registrations made before real devices were supported, which are all simulators.
    public let kind: Kind?
    /// Real devices only: marketing name, USB/Xcode hardware UDID, and whether agents may send input.
    public let model: String?
    public let hardwareUDID: String?
    public let allowInput: Bool?
    public var isDevice: Bool { kind == .device }
    /// Real phones are view-only unless input was explicitly allowed when registering.
    public var acceptsInput: Bool { !isDevice || allowInput == true }
    public var simulatorName: String { "terminal-phone · \(name)" }
    /// "iPhone 17 Pro" for either kind.
    public var displayModel: String {
        model ?? deviceType.split(separator: ".").last.map { $0.replacingOccurrences(of: "-", with: " ") } ?? deviceType
    }
    /// "iOS 26.1" for either kind.
    public var displaySystem: String {
        if isDevice { return runtime }
        guard let last = runtime.split(separator: ".").last else { return runtime }
        let parts = last.split(separator: "-")
        return parts.count > 1 ? "\(parts[0]) " + parts.dropFirst().joined(separator: ".") : String(last)
    }
    public init(name: String, udid: String, deviceType: String, runtime: String) throws {
        try validateName(name)
        guard UUID(uuidString: udid) != nil else { throw Failure("Invalid simulator UUID") }
        self.name = name; self.udid = udid; self.deviceType = deviceType; self.runtime = runtime
        kind = nil; model = nil; hardwareUDID = nil; allowInput = nil
    }
    public init(name: String, device: ConnectedDevice, allowInput: Bool) throws {
        try validateName(name)
        guard UUID(uuidString: device.identifier) != nil else { throw Failure("Invalid device identifier") }
        self.name = name; udid = device.identifier; deviceType = device.productType; runtime = "iOS \(device.osVersion)"
        kind = .device; model = device.marketingName; hardwareUDID = device.hardwareUDID; self.allowInput = allowInput
    }
}

/// A real iPhone as reported by `xcrun devicectl list devices --json-output`.
public struct ConnectedDevice {
    public let identifier: String
    public let name: String
    public let hardwareUDID: String
    public let productType: String
    public let marketingName: String
    public let osVersion: String
    public let developerMode: String
    public let pairing: String
    public let tunnel: String
    public let transport: String
    /// The device's address inside Xcode's CoreDevice tunnel, over USB or Wi-Fi.
    public let tunnelAddress: String?
    public var isIPhone: Bool { productType.hasPrefix("iPhone") }
    public var reachable: Bool { tunnel == "connected" && tunnelAddress != nil }

    public static func parse(_ data: Data) throws -> [ConnectedDevice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { throw Failure("Unexpected devicectl output") }
        return devices.compactMap { entry in
            let device = entry["deviceProperties"] as? [String: Any] ?? [:]
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = entry["connectionProperties"] as? [String: Any] ?? [:]
            guard let identifier = entry["identifier"] as? String, let product = hardware["productType"] as? String else { return nil }
            return ConnectedDevice(identifier: identifier, name: device["name"] as? String ?? product, hardwareUDID: hardware["udid"] as? String ?? "",
                                   productType: product, marketingName: hardware["marketingName"] as? String ?? product,
                                   osVersion: device["osVersionNumber"] as? String ?? "?", developerMode: device["developerModeStatus"] as? String ?? "unknown",
                                   pairing: connection["pairingState"] as? String ?? "unknown", tunnel: connection["tunnelState"] as? String ?? "unknown",
                                   transport: connection["transportType"] as? String ?? "unknown", tunnelAddress: connection["tunnelIPAddress"] as? String)
        }
    }
    /// Matches an identifier, hardware UDID or device name, case-insensitively.
    public func matches(_ query: String) -> Bool {
        [identifier, hardwareUDID, name].contains { $0.caseInsensitiveCompare(query) == .orderedSame }
    }
}

public struct PhoneStore {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["TERMINAL_PHONE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/terminal-phone")
    }
    public func directory(_ name: String) throws -> URL {
        try validateName(name)
        return root.appendingPathComponent("phones").appendingPathComponent(name)
    }
    public func load(_ name: String) throws -> Phone {
        let url = try directory(name).appendingPathComponent("phone.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("Phone '\(name)' does not exist. Run terminal-phone up \(name).") }
        let phone = try JSONDecoder().decode(Phone.self, from: Data(contentsOf: url))
        guard phone.name == name, UUID(uuidString: phone.udid) != nil else { throw Failure("Invalid phone registration") }
        return phone
    }
    public func save(_ phone: Phone) throws {
        let directory = try directory(phone.name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(phone).write(to: directory.appendingPathComponent("phone.json"), options: .atomic)
    }
    public func names() throws -> [String] {
        let directory = root.appendingPathComponent("phones")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            (try? validateName($0)) != nil && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).appendingPathComponent("phone.json").path)
        }.sorted()
    }
}

public enum PhoneInput {
    // The public CLI and idb both use display points, not screenshot pixels.
    public static func coordinate(_ raw: String) throws -> Int {
        guard let number = Int(raw), (0...16384).contains(number) else { throw Failure("Coordinates must be integer display points in 0...16384") }
        return number
    }
    public static func idbArguments(action: String, values: [String], udid: String, duration: String? = nil) throws -> [String] {
        guard UUID(uuidString: udid) != nil else { throw Failure("Invalid simulator UUID") }
        var result = ["ui"]
        switch action {
        case "tap":
            guard values.count == 2 else { throw Failure("Usage: action [NAME] tap X Y") }
            result += ["tap"] + (try values.map { String(try coordinate($0)) })
        case "swipe":
            guard values.count == 4 else { throw Failure("Usage: action [NAME] swipe X1 Y1 X2 Y2 [--duration SECONDS]") }
            result += ["swipe"] + (try values.map { String(try coordinate($0)) })
            let raw = duration ?? "0.3"
            guard let seconds = Double(raw), seconds.isFinite, (0.05...10).contains(seconds) else { throw Failure("--duration must be 0.05–10 seconds") }
            result += ["--duration", raw]
        case "type":
            guard values.count == 1, !values[0].isEmpty else { throw Failure("Usage: action [NAME] type -- 'text'") }
            // idb uses argparse; end option parsing before user text, including text beginning with '-'.
            return ["ui", "text", "--udid", udid, "--", values[0]]
        case "button":
            guard values.count == 1, ["HOME", "LOCK", "SIRI"].contains(values[0].uppercased()) else { throw Failure("Supported buttons: HOME, LOCK, SIRI") }
            result += ["button", values[0].uppercased()]
        case "key":
            let codes = ["return": 40, "escape": 41, "backspace": 42, "tab": 43, "delete": 76, "right": 79, "left": 80, "down": 81, "up": 82]
            guard values.count == 1, let code = codes[values[0]] else { throw Failure("Supported keys: return, escape, backspace, tab, delete, right, left, down, up") }
            result += ["key", String(code)]
        case "describe":
            guard values.isEmpty else { throw Failure("Usage: action [NAME] describe") }
            result += ["describe-all"]
        default: throw Failure("Unknown touch action: \(action)")
        }
        return result + ["--udid", udid]
    }
}
