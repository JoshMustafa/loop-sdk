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

    func test_round_trip_of_incompressible_data_spanning_many_output_chunks() throws {
        // 300 KB from a seeded xorshift generator: barely compressible, so both
        // compress and decompress fill the 64 KB output buffer several times.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 0, count: 300 * 1024)
        for i in bytes.indices {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            bytes[i] = UInt8(truncatingIfNeeded: state)
        }
        let input = Data(bytes)
        let zipped = try Gzip.compress(input)
        XCTAssertGreaterThan(zipped.count, 64 * 1024, "compressed output should span several chunks")
        XCTAssertEqual(try Gzip.decompress(zipped), input)
    }
}
