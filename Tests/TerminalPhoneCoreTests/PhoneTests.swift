import XCTest
import Foundation
@testable import TerminalPhoneCore

final class PhoneTests: XCTestCase {
    func testAspectAndHitCoordinatesWithTallTerminalCells() {
        // Reproduce a terminal whose cells are much taller than the old 8x16 guess.
        let layout = PhoneDisplayLayout(width: 402, height: 874, columns: 100, rows: 40, cellWidth: 8, cellHeight: 21)
        XCTAssertEqual(layout.pixelWidth / layout.pixelHeight, 402.0 / 874, accuracy: 0.00001)
        XCTAssertTrue(layout.heightLimited)
        XCTAssertGreaterThan(layout.column, 1)
        let point = layout.point(column: 50, row: 12)!
        XCTAssertTrue((180...220).contains(point.0))
        XCTAssertTrue((245...278).contains(point.1))
        XCTAssertNil(layout.point(column: 1, row: 12))
        XCTAssertEqual(layout.point(column: 1000, row: 1000, clamp: true)?.0, 401)
        let narrow = PhoneDisplayLayout(width: 402, height: 874, columns: 10, rows: 40, cellWidth: 8, cellHeight: 21)
        XCTAssertFalse(narrow.heightLimited)
        XCTAssertEqual(narrow.pixelWidth / narrow.pixelHeight, 402.0 / 874, accuracy: 0.00001)
    }
    func testFragmentedTerminalMetricsAreNotTypedIntoThePhone() {
        var filter = PhoneMetricFilter()
        XCTAssertEqual(filter.feed(Array("\u{1b}[6;21;".utf8)), [])
        XCTAssertEqual(filter.feed(Array("8tHello\u{1b}[<0;50;12M".utf8)), Array("Hello\u{1b}[<0;50;12M".utf8))
        XCTAssertEqual(filter.cellWidth, 8)
        XCTAssertEqual(filter.cellHeight, 21)
        XCTAssertEqual(filter.feed(Array("\u{1b}]1337;ReportCellSize=24;9;2\u{7}".utf8)), [])
        XCTAssertEqual(filter.cellHeight, 24)
        XCTAssertEqual(filter.cellWidth, 9)
        XCTAssertEqual(filter.feed(Array("\u{1b}[4;960;900t".utf8)), [])
        XCTAssertEqual(filter.windowWidth, 900)
        XCTAssertEqual(filter.feed([27]), [])
        XCTAssertEqual(filter.feed([], flush: true), [27])
    }
    func testRegionLayoutCentersInsideItsOrigin() {
        let layout = PhoneDisplayLayout(width: 402, height: 874, column: 11, row: 3, columns: 60, rows: 30, cellWidth: 16, cellHeight: 34)
        XCTAssertTrue(layout.heightLimited)
        XCTAssertEqual(layout.row, 3)
        XCTAssertEqual(layout.rows, 30)
        XCTAssertEqual(layout.column, 11 + (60 - layout.columns) / 2)
        XCTAssertEqual(layout.pixelHeight, 30 * 34)
        XCTAssertNil(layout.point(column: 10, row: 10))
    }
    func testKittyGraphicsRepliesAreSwallowed() {
        var filter = PhoneMetricFilter()
        XCTAssertEqual(filter.feed(Array("a\u{1b}_Gi=31;O".utf8)), Array("a".utf8))
        XCTAssertEqual(filter.feed(Array("K\u{1b}\\b".utf8)), Array("b".utf8))
        XCTAssertEqual(filter.graphicsReplies[31], "OK")
        XCTAssertEqual(filter.feed(Array("\u{1b}_Gi=31;EBADF:no shm\u{1b}\\".utf8)), [])
        XCTAssertEqual(filter.graphicsReplies[31], "EBADF:no shm")
        XCTAssertEqual(filter.feed(Array("\u{1b}]1337;ReportCellSize=17.0;8.0;2.0\u{7}".utf8)), [])
        XCTAssertEqual(filter.cellScale, 2)
    }
    func testFramedViewportFitsWholeCellsAndMapsThroughTheBezel() {
        let frame = DeviceFrame(screenWidth: 402, screenHeight: 874)
        let v = PhoneViewport(frame: frame, column: 1, row: 4, columns: 100, rows: 40, cellWidth: 16, cellHeight: 34)
        XCTAssertEqual(v.rows, 40)
        XCTAssertEqual(v.canvasHeight, 40 * 34)
        XCTAssertEqual(v.canvasWidth, v.columns * 16)
        XCTAssertFalse(v.overflowsX || v.overflowsY)
        XCTAssertEqual(v.scale, 40 * 34 / frame.height, accuracy: 0.0001)
        // The middle cell lands near the middle of the screen; the outer bezel is not the screen.
        let middle = v.point(column: v.column + v.columns / 2, row: v.row + v.rows / 2)!
        XCTAssertEqual(Double(middle.0), 201, accuracy: 12)
        XCTAssertEqual(Double(middle.1), 437, accuracy: 20)
        XCTAssertNil(v.point(column: v.column, row: v.row))
        XCTAssertEqual(v.point(column: v.column, row: v.row, clamp: true)?.0, 0)
        let cells = v.screenCells
        XCTAssertGreaterThan(cells.columns, v.columns - 8)
        XCTAssertGreaterThan(cells.row, v.row - 1)
    }
    func testZoomedViewportCropsAndPans() {
        let frame = DeviceFrame(screenWidth: 402, screenHeight: 874)
        let top = PhoneViewport(frame: frame, column: 1, row: 1, columns: 100, rows: 40, cellWidth: 16, cellHeight: 34, zoom: 2, pan: (0.5, 0))
        XCTAssertTrue(top.overflowsY)
        XCTAssertEqual(top.rows, 40)
        XCTAssertEqual(top.originY, 0, accuracy: 0.001)
        let bottom = PhoneViewport(frame: frame, column: 1, row: 1, columns: 100, rows: 40, cellWidth: 16, cellHeight: 34, zoom: 2, pan: (0.5, 1))
        XCTAssertEqual(bottom.originY, -(frame.height * bottom.scale - Double(bottom.canvasHeight)), accuracy: 0.001)
        // The same cell shows a lower part of the screen when panned down.
        XCTAssertGreaterThan(bottom.point(column: 50, row: 20)!.1, top.point(column: 50, row: 20)!.1)
        let small = PhoneViewport(frame: frame, column: 1, row: 1, columns: 100, rows: 40, cellWidth: 16, cellHeight: 34, zoom: 0.5)
        XCTAssertLessThan(small.rows, 22)
        XCTAssertEqual(small.row, 1 + (40 - small.rows) / 2)
    }
    func testTerminalBackgroundReplyIsSwallowed() {
        var filter = PhoneMetricFilter()
        XCTAssertEqual(filter.feed(Array("\u{1b}]11;rgb:1a1a/1b1b/2626\u{1b}\\x".utf8)), Array("x".utf8))
        XCTAssertEqual(filter.background, 0x1a1b26)
    }
    func testParsesPairedIPhonesFromDevicectl() throws {
        let json: [String: Any] = ["result": ["devices": [
            ["identifier": "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9",
             "deviceProperties": ["name": "Test iPhone", "osVersionNumber": "27.0", "developerModeStatus": "enabled"],
             "hardwareProperties": ["udid": "00008140-000A1B2C3D4E5F6A", "productType": "iPhone17,4", "marketingName": "iPhone 16 Plus"],
             "connectionProperties": ["tunnelState": "connected", "tunnelIPAddress": "fd00:1234:5678::1", "transportType": "localNetwork", "pairingState": "paired"]],
            ["identifier": "11111111-2222-3333-4444-555555555555",
             "deviceProperties": ["name": "Watch"], "hardwareProperties": ["productType": "Watch7,1"], "connectionProperties": ["tunnelState": "disconnected"]]
        ]]]
        let devices = try ConnectedDevice.parse(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(devices.count, 2)
        let phone = devices[0]
        XCTAssertTrue(phone.isIPhone && phone.reachable)
        XCTAssertFalse(devices[1].isIPhone || devices[1].reachable)
        XCTAssertTrue(phone.matches("test iphone"))
        XCTAssertTrue(phone.matches("00008140-000A1B2C3D4E5F6A"))
        let registered = try Phone(name: "iphone", device: phone, allowInput: false)
        XCTAssertTrue(registered.isDevice)
        XCTAssertFalse(registered.acceptsInput)
        XCTAssertEqual(registered.displayModel, "iPhone 16 Plus")
        XCTAssertEqual(registered.displaySystem, "iOS 27.0")
    }
    func testRegistrationsFromBeforeDevicesStillLoadAsSimulators() throws {
        let legacy = #"{"deviceType":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro","runtime":"com.apple.CoreSimulator.SimRuntime.iOS-26-1","name":"default","udid":"1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F"}"#
        let phone = try JSONDecoder().decode(Phone.self, from: Data(legacy.utf8))
        XCTAssertFalse(phone.isDevice)
        XCTAssertTrue(phone.acceptsInput)
        XCTAssertEqual(phone.displayModel, "iPhone 17 Pro")
        XCTAssertEqual(phone.displaySystem, "iOS 26.1")
    }
    let udid = "A1122334-5566-7788-9900-AABBCCDDEEFF"
    func catalog() throws -> SimulatorCatalog {
        let fixture: [String: Any] = [
            "runtimes": [
                ["identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-1", "name": "iOS 26.1", "version": "26.1", "isAvailable": true],
                ["identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-6", "name": "iOS 18.6", "version": "18.6", "isAvailable": true],
                ["identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "name": "iOS 27.0", "version": "27.0", "isAvailable": false],
                ["identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-30-0", "name": "watchOS 30", "version": "30.0", "isAvailable": true]
            ],
            "devicetypes": [
                ["identifier": "new-phone", "name": "iPhone New", "productFamily": "iPhone", "minRuntimeVersion": 1703936],
                ["identifier": "old-phone", "name": "iPhone Old", "productFamily": "iPhone", "minRuntimeVersion": 1179648, "maxRuntimeVersion": 1245183],
                ["identifier": "tablet", "name": "iPad Pro", "productFamily": "iPad", "minRuntimeVersion": 1179648]
            ],
            "devices": ["com.apple.CoreSimulator.SimRuntime.iOS-26-1": [
                ["udid": udid, "name": "terminal-phone · work", "state": "Booted", "deviceTypeIdentifier": "new-phone", "isAvailable": true],
                ["udid": "B1122334-5566-7788-9900-AABBCCDDEEFF", "name": "Personal iPhone", "state": "Booted", "deviceTypeIdentifier": "new-phone", "isAvailable": true]
            ]]
        ]
        return try JSONDecoder().decode(SimulatorCatalog.self, from: JSONSerialization.data(withJSONObject: fixture))
    }
    func testSelectsNewestAvailableCompatibleIOSAndRespectsChoice() throws {
        let c = try catalog()
        XCTAssertEqual(try c.select(device: nil, runtime: nil).1.version, "26.1")
        XCTAssertEqual(try c.select(device: "iPhone Old", runtime: nil).1.version, "18.6")
        XCTAssertEqual(try c.select(device: nil, runtime: "18.6").0.identifier, "old-phone")
        XCTAssertThrowsError(try c.select(device: "iPhone Old", runtime: "26.1"))
        XCTAssertThrowsError(try c.select(device: "iPad Pro", runtime: nil))
        XCTAssertThrowsError(try c.select(device: nil, runtime: "27.0"))
    }
    func testPhoneOwnershipRequiresMatchingUUIDNameTypeAndRuntime() throws {
        let c = try catalog()
        let phone = try Phone(name: "work", udid: udid, deviceType: "new-phone", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-1")
        XCTAssertEqual(try c.device(for: phone).state, "Booted")
        for changed in [
            try Phone(name: "different", udid: udid, deviceType: "new-phone", runtime: phone.runtime),
            try Phone(name: "work", udid: udid, deviceType: "old-phone", runtime: phone.runtime),
            try Phone(name: "work", udid: udid, deviceType: "new-phone", runtime: "other"),
            try Phone(name: "work", udid: "B1122334-5566-7788-9900-AABBCCDDEEFF", deviceType: "new-phone", runtime: phone.runtime)
        ] { XCTAssertThrowsError(try c.device(for: changed)) }
    }
    func testTouchArgumentsPinDeviceAndPreserveTextAsOneLiteralArgument() throws {
        XCTAssertEqual(try PhoneInput.idbArguments(action: "tap", values: ["120", "300"], udid: udid), ["ui", "tap", "120", "300", "--udid", udid])
        let literal = "--udid other; $(touch /tmp/no) '🦊'\nline"
        XCTAssertEqual(try PhoneInput.idbArguments(action: "type", values: [literal], udid: udid), ["ui", "text", "--udid", udid, "--", literal])
        XCTAssertThrowsError(try PhoneInput.idbArguments(action: "tap", values: ["nan", "4"], udid: udid))
        XCTAssertThrowsError(try PhoneInput.idbArguments(action: "tap", values: ["-1", "4"], udid: udid))
        XCTAssertThrowsError(try PhoneInput.idbArguments(action: "swipe", values: ["0", "0", "20", "20"], udid: udid, duration: "nan"))
        XCTAssertThrowsError(try PhoneInput.idbArguments(action: "button", values: ["POWER_ALL"], udid: udid))
        XCTAssertThrowsError(try PhoneInput.idbArguments(action: "tap", values: ["0", "0"], udid: "booted"))
        XCTAssertEqual(try PhoneInput.idbArguments(action: "key", values: ["return"], udid: udid), ["ui", "key", "40", "--udid", udid])
    }
    func testStoreDoesNotRegisterOrListOtherSimulatorData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhoneStore(root: root)
        XCTAssertEqual(try store.names(), [])
        XCTAssertThrowsError(try store.load("default"))
        XCTAssertThrowsError(try store.directory("../other"))
        let p = try Phone(name: "work", udid: udid, deviceType: "new-phone", runtime: "ios")
        try store.save(p)
        XCTAssertEqual(try store.names(), ["work"])
        XCTAssertEqual(try store.load("work").udid, udid)
        XCTAssertThrowsError(try Phone(name: "work", udid: "booted", deviceType: "phone", runtime: "ios"))
    }
    func testCommandRunnerHandlesLargeOutputAndFailure() async throws {
        let result = try await CommandRunner.run("/usr/bin/awk", ["BEGIN { for(i=0;i<100000;i++) printf \"x\"; exit 7 }"])
        XCTAssertEqual(result.output.count, 100000)
        XCTAssertEqual(result.status, 7)
        do { _ = try await CommandRunner.checked("/usr/bin/false", []); XCTFail("Expected failure") } catch {}
    }
    func testCommandDeadlineDoesNotHang() async throws {
        let start = Date()
        do { _ = try await CommandRunner.run("/bin/sleep", ["5"], timeout: 0.1); XCTFail("Expected timeout") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
}
