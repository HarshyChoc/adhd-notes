import XCTest
@testable import StickyNotes

final class ModifierChordRecognizerTests: XCTestCase {
    func testControlOptionCreatesOnlyAfterCompleteRelease() {
        var recognizer = ModifierChordRecognizer()
        XCTAssertNil(recognizer.handleFlagsChanged([.control]))
        XCTAssertNil(recognizer.handleFlagsChanged([.control, .option]))
        XCTAssertNil(recognizer.handleFlagsChanged([.option]))
        XCTAssertEqual(recognizer.handleFlagsChanged([]), .createNote)
        XCTAssertNil(recognizer.handleFlagsChanged([]))
    }

    func testOptionCommandTogglesOnlyAfterCompleteRelease() {
        var recognizer = ModifierChordRecognizer()
        XCTAssertNil(recognizer.handleFlagsChanged([.option, .command]))
        XCTAssertNil(recognizer.handleFlagsChanged([.command]))
        XCTAssertEqual(recognizer.handleFlagsChanged([]), .toggleVisibility)
    }

    func testNonModifierKeyCancelsChord() {
        var recognizer = ModifierChordRecognizer()
        XCTAssertNil(recognizer.handleFlagsChanged([.control, .option]))
        recognizer.handleNonModifierKeyDown()
        XCTAssertNil(recognizer.handleFlagsChanged([]))
    }

    func testAnotherModifierEventCancelsChord() {
        var recognizer = ModifierChordRecognizer()
        XCTAssertNil(recognizer.handleFlagsChanged([.control, .option]))
        recognizer.handleExtraModifier()
        XCTAssertNil(recognizer.handleFlagsChanged([]))
    }

    func testExtraModifierCancelsChord() {
        var recognizer = ModifierChordRecognizer()
        XCTAssertNil(recognizer.handleFlagsChanged([.option, .command]))
        XCTAssertNil(recognizer.handleFlagsChanged([.option, .command, .shift]))
        XCTAssertNil(recognizer.handleFlagsChanged([]))
    }

    func testPartialChordNeverArms() {
        var recognizer = ModifierChordRecognizer()
        XCTAssertNil(recognizer.handleFlagsChanged([.option]))
        XCTAssertNil(recognizer.handleFlagsChanged([]))
    }
}
