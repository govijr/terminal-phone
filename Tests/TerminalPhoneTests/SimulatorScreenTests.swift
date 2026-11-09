import XCTest
import TerminalPhoneCore
@testable import TerminalPhone

final class SimulatorScreenTests: XCTestCase {
    @MainActor
    private func screen(profile: [String: Any] = [:], capabilities: [String: Any] = [:]) throws -> PhoneScreen {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        for (name, value) in [("profile", profile), ("capabilities", ["capabilities": capabilities])] {
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
                .write(to: resources.appendingPathComponent("\(name).plist"))
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "runtimes": [], "devices": [:],
            "devicetypes": [["identifier": "test.phone", "name": "Test Phone", "bundlePath": bundle.path]]
        ])
        let catalog = try JSONDecoder().decode(SimulatorCatalog.self, from: data)
        let phone = try Phone(name: "test", udid: UUID().uuidString, deviceType: "test.phone", runtime: "test.runtime")
        return try PhoneCLI().screen(phone, catalog: catalog)
    }

    @MainActor func testLegacyProfile() async throws {
        let value = try screen(profile: ["mainScreenScale": 2, "mainScreenWidth": 750, "mainScreenHeight": 1334])
        XCTAssertEqual(value.scale, 2)
        XCTAssertEqual(value.width, 375)
        XCTAssertEqual(value.height, 667)
    }

    @MainActor func testCapabilitiesScreenDimensions() async throws {
        let value = try screen(capabilities: ["ScreenDimensionsCapability": [
            "main-screen-scale": 3, "main-screen-width": 1206, "main-screen-height": 2622
        ]])
        XCTAssertEqual(value.scale, 3)
        XCTAssertEqual(value.width, 402)
        XCTAssertEqual(value.height, 874)
    }

    @MainActor func testPrimaryDisplayInsteadOfExternalDisplay() async throws {
        let value = try screen(capabilities: ["displays": [
            ["deviceName": "external-0", "displayType": "tvOut", "scale": 1, "width": 720, "height": 480],
            ["deviceName": "primary", "displayType": "integrated", "scale": 3, "width": 1206, "height": 2622]
        ]])
        XCTAssertEqual(value.scale, 3)
        XCTAssertEqual(value.width, 402)
        XCTAssertEqual(value.height, 874)
    }

    @MainActor func testUnknownOrInvalidGeometryStillFails() async throws {
        XCTAssertThrowsError(try screen())
        XCTAssertThrowsError(try screen(capabilities: ["ScreenDimensionsCapability": [
            "main-screen-scale": 0, "main-screen-width": 1206, "main-screen-height": 2622
        ]]))
        XCTAssertThrowsError(try screen(capabilities: ["displays": [
            ["deviceName": "external-0", "displayType": "tvOut", "scale": 1, "width": 720, "height": 480]
        ]]))
    }
}
