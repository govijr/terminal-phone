import XCTest
@testable import TerminalPhone

final class ViewerLayoutTests: XCTestCase {
    func testRoomyPaneReservesHeaderAndToolbar() {
        let rows = PhoneViewer.phoneRows(rows: 40, roomy: true, focus: false)
        XCTAssertEqual(rows.top, 4)
        XCTAssertEqual(rows.bottom, 37)
    }

    func testSmallPaneReservesOneRowEachSide() {
        let rows = PhoneViewer.phoneRows(rows: 12, roomy: false, focus: false)
        XCTAssertEqual(rows.top, 2)
        XCTAssertEqual(rows.bottom, 11)
    }

    func testFocusModeGivesThePhoneEveryRow() {
        for roomy in [true, false] {
            let rows = PhoneViewer.phoneRows(rows: 40, roomy: roomy, focus: true)
            XCTAssertEqual(rows.top, 1)
            XCTAssertEqual(rows.bottom, 40)
        }
    }

    func testRoomyNeedsTwentyRowsAndThirtyColumns() {
        XCTAssertTrue(PhoneViewer.isRoomy(rows: 20, columns: 30))
        XCTAssertFalse(PhoneViewer.isRoomy(rows: 19, columns: 80))
        XCTAssertFalse(PhoneViewer.isRoomy(rows: 40, columns: 29))
    }
}
