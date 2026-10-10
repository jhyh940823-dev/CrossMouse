import XCTest
@testable import CrossMouseCore

final class TransferGeometryTests: XCTestCase {
    func testOwnershipAndVisibilityAreAuthenticatedFields() throws {
        let message = CrossMouseMessage(type:"entered", transferId:"current-id", reason:"hdmi-observed",
            capability:"handoff-2", version:"0.4.0", pointerVisible:true)
        let key = Data(repeating:7, count:32)
        let frame = try CrossMouseWire.frame(message, sessionKey:key, sequence:1, direction:.windowsToMac)
        XCTAssertEqual(try CrossMouseWire.open(Data(frame.dropFirst(4)), sessionKey:key,
            sequence:1, direction:.windowsToMac), message)
        let old = try JSONDecoder().decode(CrossMouseMessage.self, from:Data(#"{"type":"pong"}"#.utf8))
        XCTAssertNil(old.capability)
        XCTAssertNil(old.transferId)
        XCTAssertNil(old.pointerVisible)
    }
    func testOnlyActualAnchorGeometryRequiresReclaim() {
        let samsung = CursorAnchorGeometry(displayID:1, bounds:CGRect(x:0,y:0,width:1920,height:1080))
        XCTAssertFalse(samsung.requiresReclaim(after:samsung, online:true))
        XCTAssertTrue(samsung.requiresReclaim(after:samsung, online:false))
        XCTAssertTrue(samsung.requiresReclaim(after:.init(displayID:2,bounds:samsung.bounds),online:true))
        XCTAssertTrue(samsung.requiresReclaim(after:.init(displayID:1,bounds:.zero),online:true))
    }
}
