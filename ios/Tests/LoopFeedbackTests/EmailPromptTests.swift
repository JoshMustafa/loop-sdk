import XCTest
import LoopCore
import LoopTestSupport
@testable import LoopFeedback

final class EmailPromptTests: XCTestCase {
    func test_plausible_addresses_are_accepted() {
        for address in ["a@b.co", "first.last+tag@example.co.uk", " padded@example.com "] {
            XCTAssertTrue(LoopEmailPrompt.isPlausible(address), address)
        }
    }

    func test_obvious_rubbish_is_rejected() {
        for address in ["", "   ", "nope", "@example.com", "a@", "a b@example.com"] {
            XCTAssertFalse(LoopEmailPrompt.isPlausible(address), address)
        }
    }

    // Deliberately loose. Address validation by regex is a known trap, and the
    // double opt-in is what actually proves an address is real and consented —
    // this only catches typos before a pointless round-trip.
    func test_unusual_but_valid_addresses_are_not_rejected() {
        XCTAssertTrue(LoopEmailPrompt.isPlausible("user@sub.domain.museum"))
    }
}
