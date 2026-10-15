import CoreGraphics
import XCTest
@testable import CommonPlaceKit

final class BothCommandsGestureTests: XCTestCase {
    private let left = BothSidesGesture.leftCommand
    private let right = BothSidesGesture.rightCommand
    /// NSEvent's device-independent ⌘ bit, set with either key.
    private let command: UInt64 = 0x0010_0000
    private let shift: UInt64 = 0x0002_0000

    func testLeftThenRightFiresOnce() {
        var gesture = CaptureKeys.bothCommands.gesture!
        XCTAssertFalse(gesture.flagsChanged(command | left))
        XCTAssertTrue(gesture.flagsChanged(command | left | right))
        // Still held: no second capture.
        XCTAssertFalse(gesture.flagsChanged(command | left | right))
        XCTAssertFalse(gesture.flagsChanged(command | right))
        XCTAssertFalse(gesture.flagsChanged(0))
        // Released and pressed again: again.
        XCTAssertFalse(gesture.flagsChanged(command | right))
        XCTAssertTrue(gesture.flagsChanged(command | right | left))
    }

    func testAShortcutWithOneCommandNeverFires() {
        var gesture = CaptureKeys.bothCommands.gesture!
        XCTAssertFalse(gesture.flagsChanged(command | left))
        gesture.keyDown()  // ⌘C
        XCTAssertFalse(gesture.flagsChanged(command | left | right))
        XCTAssertFalse(gesture.flagsChanged(0))
        // The next clean press works.
        XCTAssertFalse(gesture.flagsChanged(command | left))
        XCTAssertTrue(gesture.flagsChanged(command | left | right))
    }

    func testBothOptionKeysAndTheShortcut() {
        var gesture = CaptureKeys.bothOptions.gesture!
        let option = BothSidesGesture.option
        XCTAssertFalse(gesture.flagsChanged(option | BothSidesGesture.leftOption))
        XCTAssertTrue(gesture.flagsChanged(option | BothSidesGesture.leftOption | BothSidesGesture.rightOption))
        // Both ⌘ do nothing when ⌥ is chosen.
        var commands = CaptureKeys.bothOptions.gesture!
        XCTAssertFalse(commands.flagsChanged(command | left | right))
        XCTAssertNil(CaptureKeys.shortcut.gesture)
        let mods = BothSidesGesture.control | BothSidesGesture.option | BothSidesGesture.command
        XCTAssertTrue(CaptureKeys.isShortcut(keyCode: 40, flags: mods | 0x8))
        XCTAssertFalse(CaptureKeys.isShortcut(keyCode: 40, flags: mods | BothSidesGesture.shift))
        XCTAssertFalse(CaptureKeys.isShortcut(keyCode: 41, flags: mods))
    }

    /// Found live: an Escape typed before the gesture made the next ⌘⌘ do nothing.
    func testTypingBeforehandDoesNotSpoilTheGesture() {
        var gesture = CaptureKeys.bothCommands.gesture!
        gesture.keyDown()  // typing, no ⌘ held
        gesture.keyDown()
        XCTAssertFalse(gesture.flagsChanged(command | left))
        XCTAssertTrue(gesture.flagsChanged(command | left | right))
    }

    func testAnotherModifierSpoilsIt() {
        var gesture = CaptureKeys.bothCommands.gesture!
        XCTAssertFalse(gesture.flagsChanged(command | left | shift))
        XCTAssertFalse(gesture.flagsChanged(command | left | right | shift))
        XCTAssertFalse(gesture.flagsChanged(command | left | right))
        XCTAssertFalse(gesture.flagsChanged(0))
        XCTAssertFalse(gesture.flagsChanged(command | right))
        XCTAssertTrue(gesture.flagsChanged(command | right | left))
    }
}

final class WindowChoiceTests: XCTestCase {
    /// A MacBook Pro's list (2026-10-14): Comet's untitled toolbar windows
    /// above its titled page, then VS Code; CommonPlace's own window on top.
    private let list = [
        WindowEntry(number: 1, pid: 1, owner: "Window Server", layer: 25, x: 0, y: 0, width: 1512, height: 33),
        WindowEntry(number: 99, pid: 4000, owner: "CommonPlace", title: "CommonPlace", x: 100, y: 100, width: 900, height: 600),
        WindowEntry(number: 40486, pid: 81218, owner: "Comet", x: 0, y: 33, width: 1512, height: 43),
        WindowEntry(number: 40487, pid: 81218, owner: "Comet", x: 0, y: 76, width: 1512, height: 42),
        WindowEntry(number: 40488, pid: 81218, owner: "Comet", x: 0, y: 33, width: 1512, height: 121),
        WindowEntry(number: 40100, pid: 81218, owner: "Comet", title: "Espresso - Wikipedia", x: 0, y: 118, width: 1512, height: 864),
        WindowEntry(number: 39000, pid: 500, owner: "Code", title: "commonplace", x: 0, y: 33, width: 1400, height: 880),
    ]

    func testThePageIsKeptNotTheToolbars() {
        XCTAssertEqual(WindowChoice.pick(list, frontmostPID: 81218, excludingPID: 4000)?.number, 40100)
    }

    /// The test Mac (2026-10-14): Comet's "Restore pages?" bubble, titled,
    /// above its page; the focused window (Accessibility) is the browser
    /// window, toolbars included.
    func testTheFocusedWindowsFrameFindsThePageUnderAPopUp() {
        let bubble = WindowEntry(number: 86, pid: 81218, owner: "Comet", title: "Restore pages?", x: 1035, y: 78, width: 320, height: 148)
        let focused = CGRect(x: 0, y: 33, width: 1512, height: 949)
        XCTAssertEqual(WindowChoice.pick([bubble] + list, frontmostPID: 81218, excludingPID: 4000, focusedFrame: focused)?.number, 40100)
        // Without the frame, the titled bubble wins: why the frame is asked for.
        XCTAssertEqual(WindowChoice.pick([bubble] + list, frontmostPID: 81218, excludingPID: 4000)?.number, 86)
        // A frame that overlaps none of the app's windows changes nothing.
        XCTAssertEqual(WindowChoice.pick(list, frontmostPID: 500, excludingPID: 4000,
                                         focusedFrame: CGRect(x: 5000, y: 5000, width: 10, height: 10))?.number, 39000)
    }

    func testTheFrontmostAppWins() {
        XCTAssertEqual(WindowChoice.pick(list, frontmostPID: 500, excludingPID: 4000)?.number, 39000)
    }

    func testOwnWindowsAreNeverKept() {
        XCTAssertEqual(WindowChoice.pick(list, frontmostPID: 4000, excludingPID: 4000)?.number, 40100)
    }

    func testWithoutATitleTheLargestWindow() {
        let untitled = [
            WindowEntry(number: 5, pid: 7, owner: "Editor", x: 0, y: 0, width: 800, height: 120),
            WindowEntry(number: 6, pid: 7, owner: "Editor", x: 0, y: 120, width: 800, height: 700),
        ]
        XCTAssertEqual(WindowChoice.pick(untitled, frontmostPID: 7)?.number, 6)
    }

    func testOnlyBarsIsNoWindow() {
        XCTAssertNil(WindowChoice.pick(Array(list[0...0] + list[2...3]), frontmostPID: 81218))
    }
}
