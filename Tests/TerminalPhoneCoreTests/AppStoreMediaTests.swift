import XCTest
import TerminalPhoneCore

final class AppStoreMediaTests: XCTestCase {
    func testDisplayNamesAcceptCommonSpellings() {
        XCTAssertEqual(AppStoreDisplay(named: "6.9"), .iphone69)
        XCTAssertEqual(AppStoreDisplay(named: "6.9in"), .iphone69)
        XCTAssertEqual(AppStoreDisplay(named: "iphone-6.3"), .iphone63)
        XCTAssertEqual(AppStoreDisplay(named: "6.7"), .iphone69)
        XCTAssertEqual(AppStoreDisplay(named: "13"), .ipad13)
        XCTAssertEqual(AppStoreDisplay(named: "ipad-11"), .ipad11)
        XCTAssertEqual(AppStoreDisplay(named: "12.9-inch"), .ipad13)
        XCTAssertNil(AppStoreDisplay(named: "7.2"))
    }

    func testAutoMatchesTheSimulatorExactly() {
        XCTAssertEqual(AppStoreDisplay.auto(for: PixelSize(1320, 2868)), .iphone69)   // 17 Pro Max
        XCTAssertEqual(AppStoreDisplay.auto(for: PixelSize(1206, 2622)), .iphone63)   // 17 Pro
        XCTAssertEqual(AppStoreDisplay.auto(for: PixelSize(2868, 1320)), .iphone69)   // landscape
        XCTAssertEqual(AppStoreDisplay.auto(for: PixelSize(2064, 2752)), .ipad13)
        XCTAssertEqual(AppStoreDisplay.auto(for: PixelSize(1000, 2200)), .iphone69)   // unknown phone
        XCTAssertEqual(AppStoreDisplay.auto(for: PixelSize(1600, 2100)), .ipad13)     // unknown tablet
    }

    func testScreenshotSizeKeepsAcceptedSourcesAndOrientation() {
        XCTAssertEqual(AppStoreDisplay.iphone69.screenshotSize(for: PixelSize(1290, 2796)), PixelSize(1290, 2796))
        XCTAssertEqual(AppStoreDisplay.iphone69.screenshotSize(for: PixelSize(1206, 2622)), PixelSize(1320, 2868))
        XCTAssertEqual(AppStoreDisplay.iphone69.screenshotSize(for: PixelSize(2622, 1206)), PixelSize(2868, 1320))
        XCTAssertEqual(AppStoreDisplay.iphone55.screenshotSize(for: PixelSize(1206, 2622)), PixelSize(1242, 2208))
        // Every accepted size is in the published list, portrait first.
        for display in AppStoreDisplay.allCases { XCTAssertTrue(display.screenshotSizes.allSatisfy { !$0.landscape }) }
    }

    func testPreviewSizesAreTheAcceptedOnesNotDeviceResolution() {
        XCTAssertEqual(AppStoreDisplay.iphone69.previewSize(landscape: false), PixelSize(886, 1920))
        XCTAssertEqual(AppStoreDisplay.iphone63.previewSize(landscape: true), PixelSize(1920, 886))
        XCTAssertEqual(AppStoreDisplay.iphone55.previewSize, PixelSize(1080, 1920))
        XCTAssertEqual(AppStoreDisplay.ipad13.previewSize, PixelSize(1200, 1600))
        // H.264 needs even dimensions.
        for display in AppStoreDisplay.allCases { XCTAssertEqual(display.previewSize.width % 2, 0); XCTAssertEqual(display.previewSize.height % 2, 0) }
    }

    func testBareScreenFillsTheCanvas() {
        let layout = MediaLayout.make(content: (1206, 2622), canvas: PixelSize(1320, 2868), decorated: false, caption: false)
        XCTAssertTrue(layout.fills)
        XCTAssertGreaterThanOrEqual(layout.content.width, 1320 - 0.001)
        XCTAssertGreaterThanOrEqual(layout.content.height, 2868 - 0.001)
        XCTAssertEqual(layout.content.x + layout.content.width / 2, 660, accuracy: 0.001)
    }

    func testDecoratedPhoneFitsInsideMarginsUnderTheCaption() {
        let canvas = PixelSize(1320, 2868)
        let layout = MediaLayout.make(content: (1300, 2700), canvas: canvas, decorated: true, caption: true)
        XCTAssertFalse(layout.fills)
        let caption = try! XCTUnwrap(layout.caption)
        XCTAssertGreaterThanOrEqual(layout.content.y, caption.y + caption.height - 0.001)
        XCTAssertGreaterThan(layout.content.x, 0)
        XCTAssertLessThanOrEqual(layout.content.x + layout.content.width, Double(canvas.width))
        XCTAssertLessThanOrEqual(layout.content.y + layout.content.height, Double(canvas.height))
        XCTAssertEqual(layout.content.width / layout.content.height, 1300.0 / 2700.0, accuracy: 0.0001)
    }

    func testNativeCanvasAddsMarginsOnlyWhenDecorated() {
        XCTAssertEqual(MediaLayout.make(content: (1207, 2623), canvas: nil, decorated: false, caption: false).canvas, PixelSize(1206, 2622))
        let framed = MediaLayout.make(content: (1300, 2700), canvas: nil, decorated: true, caption: false)
        XCTAssertGreaterThan(framed.canvas.width, 1300)
        XCTAssertEqual(framed.canvas.width % 2, 0); XCTAssertEqual(framed.canvas.height % 2, 0)
    }

    func testBackgroundParsing() {
        XCTAssertEqual(MediaBackground.parse("#1e90ff", fileExists: { _ in false }), .solid(0x1e90ff))
        XCTAssertEqual(MediaBackground.parse("fff", fileExists: { _ in false }), .solid(0xffffff))
        XCTAssertEqual(MediaBackground.parse("#0b1d3a, #3a6df0", fileExists: { _ in false }), .gradient(0x0b1d3a, 0x3a6df0))
        XCTAssertEqual(MediaBackground.parse("Midnight", fileExists: { _ in false }), .gradient(0x0b1d3a, 0x3a6df0))
        XCTAssertEqual(MediaBackground.parse("/tmp/bg.png", fileExists: { $0 == "/tmp/bg.png" }), .image("/tmp/bg.png"))
        XCTAssertNil(MediaBackground.parse("not-a-colour", fileExists: { _ in false }))
        XCTAssertTrue(MediaBackground.isLight(0xf5f5f7)); XCTAssertFalse(MediaBackground.isLight(0x0b1d3a))
    }

    func testStyleNeedsAnOpaqueBackgroundBehindAFrame() {
        XCTAssertNil(MediaStyle().resolvedBackground)
        XCTAssertTrue(MediaStyle().plain)
        XCTAssertEqual(MediaStyle(frame: .orange).resolvedBackground, MediaBackground.standard)
        XCTAssertEqual(MediaStyle(caption: "Hi").resolvedBackground, MediaBackground.standard)
        XCTAssertFalse(MediaStyle(size: .appStore(nil)).plain)
    }

    func testPreviewLengthWarnings() {
        XCTAssertEqual(AppPreviewRules.warnings(seconds: 20), [])
        XCTAssertEqual(AppPreviewRules.warnings(seconds: 8).count, 1)
    }

    func testViewportReportsWhatIsVisibleWhenZoomedIn() {
        let frame = DeviceFrame(screenWidth: 402, screenHeight: 874)
        let fitted = PhoneViewport(frame: frame, column: 1, row: 1, columns: 80, rows: 40, cellWidth: 10, cellHeight: 20)
        XCTAssertNil(fitted.visible)
        let top = PhoneViewport(frame: frame, column: 1, row: 1, columns: 80, rows: 40, cellWidth: 10, cellHeight: 20, zoom: 2, pan: (0.5, 0))
        let crop = try! XCTUnwrap(top.visible)
        XCTAssertEqual(crop.y, 0, accuracy: 0.0001)
        XCTAssertEqual(crop.height, 0.5, accuracy: 0.02)
        let bottom = PhoneViewport(frame: frame, column: 1, row: 1, columns: 80, rows: 40, cellWidth: 10, cellHeight: 20, zoom: 2, pan: (0.5, 1))
        XCTAssertEqual(bottom.visible!.y + bottom.visible!.height, 1, accuracy: 0.0001)
        // A wheel tick moves a fraction of the overflow, never past it.
        let step = top.panStep()
        XCTAssertGreaterThan(step.y, 0); XCTAssertLessThanOrEqual(step.y, 1)
    }

    func testCropOfTheFrameMapsOntoTheScreen() {
        let frame = DeviceFrame(screenWidth: 402, screenHeight: 874)
        XCTAssertEqual(MediaCrop.screen(MediaCrop.whole, in: frame), MediaCrop.whole)
        let topHalf = MediaCrop.screen(MediaRect(x: 0, y: 0, width: 1, height: 0.5), in: frame)
        XCTAssertEqual(topHalf.x, 0); XCTAssertEqual(topHalf.y, 0); XCTAssertEqual(topHalf.width, 1)
        XCTAssertLessThan(topHalf.height, 0.55); XCTAssertGreaterThan(topHalf.height, 0.45)
    }

    func testTransparencyIsOfferedOnlyAtThePhonesOwnSize() {
        XCTAssertEqual(MediaBackground.parse("transparent", fileExists: { _ in false }), .transparent)
        XCTAssertFalse(AppStoreSettings.backgrounds(asShown: false).contains("transparent"))
        XCTAssertTrue(AppStoreSettings.backgrounds(asShown: true).contains("transparent"))
        var settings = AppStoreSettings(display: "shown", background: "transparent")
        XCTAssertEqual(settings.style(finish: .black).size, .native)
        XCTAssertTrue(settings.style(finish: .black).transparent)
        settings.display = "6.9"; settings.normalize()
        XCTAssertNil(settings.background)
        // A transparent frame hugs the phone; no opaque margin is added.
        let style = MediaStyle(frame: .black, background: .transparent)
        XCTAssertNil(style.resolvedBackground); XCTAssertFalse(style.inset)
    }
}
