import XCTest
@testable import LoopCore

final class GzipTests: XCTestCase {
    func test_round_trip_and_gzip_magic_bytes() throws {
        let input = Data(String(repeating: "hello loop ", count: 500).utf8)
        let zipped = try Gzip.compress(input)
        XCTAssertEqual(Array(zipped.prefix(2)), [0x1f, 0x8b])
        XCTAssertLessThan(zipped.count, input.count)
        XCTAssertEqual(try Gzip.decompress(zipped), input)
    }
}
