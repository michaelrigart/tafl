import Foundation
import Testing
@testable import TaflCore

struct WindowMemoryTests {
    let w1 = WindowHandle(pid: 100, windowID: 1, isStable: true)
    let w2 = WindowHandle(pid: 100, windowID: 2, isStable: true)
    let w3 = WindowHandle(pid: 200, windowID: 1, isStable: true)

    func placed(_ achieved: ScreenRect = rect(0, 25, 500, 775), on display: Display = displayA) -> PlacedRecord {
        PlacedRecord(
            action: .leftHalf,
            layout: nil,
            placement: .leftHalf,
            cycleStep: 0,
            achieved: achieved,
            display: display.identity
        )
    }

    @Test func aPlaceholderFlagIsNeverStoredSoTheFileFormatStaysTheSame() throws {
        let placeholder = Display(identity: displayA.identity, frame: displayA.frame, visibleFrame: v, isPlaceholder: true)
        let data = try JSONEncoder().encode(placeholder)
        #expect(!String(decoding: data, as: UTF8.self).contains("laceholder"))
        #expect(try JSONDecoder().decode(Display.self, from: data).isPlaceholder == false)
    }

    @Test func chainStartsOnceAndSurvivesTaflPlacements() {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(100, 100, 400, 300), on: displayA)
        memory.openChain(w1, before: rect(0, 25, 500, 775), on: displayA)
        #expect(memory.restore[w1]?.frame == rect(100, 100, 400, 300))
        #expect(memory.restore[w1]?.chainOpen == true)
    }

    @Test func externalChangeStartsANewChain() {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(100, 100, 400, 300), on: displayA)
        memory.recordPlaced(w1, placed())
        memory.recordExternalChange(w1)
        #expect(memory.placed[w1] == nil)
        #expect(memory.restore[w1]?.frame == rect(100, 100, 400, 300))
        #expect(memory.restore[w1]?.chainOpen == false)
        memory.openChain(w1, before: rect(200, 200, 400, 300), on: displayA)
        #expect(memory.restore[w1]?.frame == rect(200, 200, 400, 300))
        #expect(memory.restore[w1]?.chainOpen == true)
    }

    @Test func restoreStaysOnItsDisplayWhenConnected() throws {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(1200, 150, 800, 600), on: displayB)
        let target = try #require(memory.restoreTarget(w1, current: displayA, displays: [displayA, displayB]))
        #expect(target.0 == rect(1200, 150, 800, 600))
        #expect(target.1 == displayB)
    }

    @Test func restoreMapsAMissingDisplay() throws {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(1200, 150, 800, 600), on: displayB)
        let target = try #require(memory.restoreTarget(w1, current: displayA, displays: [displayA]))
        #expect(target.0 == rect(100, 100, 400, 300))
        #expect(target.0.relative(to: v) == rect(1200, 150, 800, 600).relative(to: displayB.visibleFrame))
        #expect(target.1 == displayA)
    }

    private func movedB() -> Display {
        var moved = displayB
        moved.frame = rect(-2000, 0, 2000, 1550)
        moved.visibleFrame = moved.frame
        return moved
    }

    @Test func restoreFollowsADisplayThatMoved() throws {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(1500, 100, 400, 300), on: displayB)
        let moved = movedB()
        let target = try #require(memory.restoreTarget(w1, current: moved, displays: [displayA, moved]))
        #expect(target.0 == rect(-1500, 100, 400, 300))
        #expect(target.1 == moved)
    }

    @Test func restoreFollowsADisplayThatChangedResolution() throws {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(1500, 100, 400, 300), on: displayB)
        var smaller = displayB
        smaller.frame = rect(1000, 0, 1000, 775)
        smaller.visibleFrame = smaller.frame
        let target = try #require(memory.restoreTarget(w1, current: smaller, displays: [displayA, smaller]))
        #expect(target.0 == rect(1250, 50, 200, 150))
        #expect(target.1 == smaller)
    }

    @Test func restoreAfterTheDockAppearedOnItsDisplayIsExact() throws {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(100, 100, 400, 300), on: displayA)
        var docked = displayA
        docked.visibleFrame = rect(100, 25, 900, 775)
        let target = try #require(memory.restoreTarget(w1, current: docked, displays: [docked]))
        #expect(target.0 == rect(100, 100, 400, 300))
        #expect(target.1 == docked)
    }

    @Test func restoreAfterTheMenuBarGrewAndTheDockMovedIsExact() throws {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(1200, 150, 800, 600), on: displayB)
        var changed = displayB
        changed.visibleFrame = rect(1000, 60, 1900, 1490)
        let target = try #require(memory.restoreTarget(w1, current: changed, displays: [displayA, changed]))
        #expect(target.0 == rect(1200, 150, 800, 600))
    }

    @Test func restoreFollowsADisplayThatMovedAndKeepsAFramePartlyOffScreen() throws {
        var memory = WindowMemory()
        // A quarter of the window is on the display, the rest hangs off its right edge.
        memory.openChain(w1, before: rect(2900, 100, 400, 300), on: displayB)
        var moved = displayB
        moved.frame = rect(-5000, 0, 2000, 1550)
        moved.visibleFrame = moved.frame
        let target = try #require(memory.restoreTarget(w1, current: moved, displays: [displayA, moved]))
        #expect(target.0 == rect(-3100, 100, 400, 300))
    }

    @Test func restoreMappedOntoADisplayThatChangedResolutionKeepsAFramePartlyOffScreen() throws {
        var memory = WindowMemory()
        // Half of the window is on the display, the rest hangs off its right edge; mapped, it still does.
        memory.openChain(w1, before: rect(2800, 100, 400, 300), on: displayB)
        var smaller = displayB
        smaller.frame = rect(1000, 0, 1000, 775)
        smaller.visibleFrame = smaller.frame
        let target = try #require(memory.restoreTarget(w1, current: smaller, displays: [displayA, smaller]))
        #expect(target.0 == rect(1900, 50, 200, 150))
    }

    @Test func restoreMappedOntoTheCurrentDisplayKeepsAFramePartlyOffScreen() throws {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(2800, 100, 400, 300), on: displayB)
        let target = try #require(memory.restoreTarget(w1, current: displayA, displays: [displayA]))
        #expect(target.0 == rect(900, 75, 200, 150))
        #expect(target.1 == displayA)
    }

    @Test func restoreFollowsADisplayThatMovedAndLostSomeReservedSpace() throws {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(1500, 100, 400, 300), on: displayB)
        var moved = movedB()
        moved.visibleFrame = rect(-2000, 40, 2000, 1510)
        let target = try #require(memory.restoreTarget(w1, current: moved, displays: [displayA, moved]))
        #expect(target.0 == rect(-1500, 100, 400, 300))
    }

    @Test func restoreFromARecordWithoutTheDisplayFrameGoesByTheVisibleFrame() throws {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(100, 100, 400, 300), on: displayA)
        memory.restore[w1]?.displayFrame = nil
        let target = try #require(memory.restoreTarget(w1, current: displayA, displays: [displayA]))
        #expect(target.0 == rect(100, 100, 400, 300))
        var docked = displayA
        docked.visibleFrame = rect(100, 25, 900, 775)
        let mapped = try #require(memory.restoreTarget(w1, current: docked, displays: [docked]))
        #expect(mapped.0 == rect(190, 100, 360, 300))
    }

    @Test func aRestoreRecordFromBeforeTheDisplayFrameDecodesWithoutIt() throws {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(100, 100, 400, 300), on: displayA)
        let current = try JSONEncoder().encode(memory.restore[w1])
        #expect(try JSONDecoder().decode(RestoreRecord.self, from: current).displayFrame == displayA.frame)
        var object = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
        object["displayFrame"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(RestoreRecord.self, from: old).displayFrame == nil)
    }

    @Test func restoreFromAFileFollowsAnArrangementThatChangedSinceTheSave() throws {
        var saved = WindowMemory()
        saved.openChain(w1, before: rect(1500, 100, 400, 300), on: displayB)
        let memory = try JSONDecoder().decode(WindowMemory.self, from: JSONEncoder().encode(saved))
        let moved = movedB()
        let target = try #require(memory.restoreTarget(w1, current: moved, displays: [displayA, moved]))
        #expect(target.0 == rect(-1500, 100, 400, 300))
    }

    @Test func restoreOnAnUnchangedDisplayIsExactEvenPartlyOffScreen() throws {
        var memory = WindowMemory()
        // A quarter of the window hangs off the display's right edge.
        memory.openChain(w1, before: rect(2700, 100, 400, 300), on: displayB)
        let target = try #require(memory.restoreTarget(w1, current: displayB, displays: [displayA, displayB]))
        #expect(target.0 == rect(2700, 100, 400, 300))
    }

    @Test func restoreOfAFrameMostlyOffEveryDisplayIsKeptOnScreen() throws {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(2950, 100, 400, 300), on: displayB)
        let target = try #require(memory.restoreTarget(w1, current: displayB, displays: [displayA, displayB]))
        #expect(target.0 == rect(2600, 100, 400, 300))
    }

    @Test func restoreWithoutARecordHasNoTarget() {
        let memory = WindowMemory()
        #expect(memory.restoreTarget(w1, current: displayA, displays: [displayA]) == nil)
    }

    @Test func restoreClears() {
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(100, 100, 400, 300), on: displayA)
        memory.completeRestore(w1)
        #expect(memory.restore[w1] == nil)
        #expect(memory.restoreTarget(w1, current: displayA, displays: [displayA]) == nil)
    }

    @Test func achievedFrameAllowsOnePoint() {
        var memory = WindowMemory()
        memory.recordPlaced(w1, placed(rect(0, 25, 500, 775)))
        #expect(memory.isAtAchievedFrame(w1, frame: rect(1, 24, 501, 775)))
        #expect(!memory.isAtAchievedFrame(w1, frame: rect(2, 25, 500, 775)))
        #expect(!memory.isAtAchievedFrame(w2, frame: rect(0, 25, 500, 775)))
    }

    @Test func lastKnownIsRelative() throws {
        var memory = WindowMemory()
        let setup = DisplaySetup([displayA])
        memory.recordLastKnown(w1, frame: rect(100, 100, 400, 300), display: displayA, setup: setup)
        let stored = try #require(memory.lastKnown(w1, setup: setup))
        #expect(stored.display == displayA.identity)
        var resized = displayA
        resized.frame = rect(0, 0, 2000, 1600)
        resized.visibleFrame = rect(0, 25, 2000, 1550)
        #expect(memory.absolute(stored, in: [resized]) == rect(200, 175, 800, 600))
        #expect(memory.absolute(stored, in: [displayB]) == nil)
        var docked = displayA
        docked.visibleFrame = rect(100, 25, 900, 775)
        #expect(memory.absolute(stored, in: [docked]) == rect(100, 100, 400, 300))
        #expect(memory.lastKnown(w2, setup: setup) == nil)
        #expect(memory.lastKnown(w1, setup: DisplaySetup([displayB])) == nil)
    }

    @Test func lastSetupDerivesFromLastDisplays() {
        var memory = WindowMemory()
        #expect(memory.lastSetup == nil)
        memory.lastDisplays = [displayA, displayB]
        #expect(memory.lastSetup == DisplaySetup([displayB, displayA]))
    }

    @Test func forgetRemovesAWindowEverywhere() {
        var memory = WindowMemory()
        let setupA = DisplaySetup([displayA])
        let setupAB = DisplaySetup([displayA, displayB])
        for window in [w1, w2] {
            memory.openChain(window, before: rect(100, 100, 400, 300), on: displayA)
            memory.recordPlaced(window, placed())
            memory.recordLastKnown(window, frame: rect(100, 100, 400, 300), display: displayA, setup: setupA)
            memory.recordLastKnown(window, frame: rect(100, 100, 400, 300), display: displayA, setup: setupAB)
        }
        memory.forget(w1)
        #expect(memory.placed[w1] == nil && memory.restore[w1] == nil)
        #expect(memory.lastKnown(w1, setup: setupA) == nil && memory.lastKnown(w1, setup: setupAB) == nil)
        #expect(memory.placed[w2] != nil && memory.restore[w2] != nil)
        #expect(memory.lastKnown(w2, setup: setupA) != nil && memory.lastKnown(w2, setup: setupAB) != nil)
    }

    @Test func forgetByProcessRemovesEveryWindowOfIt() {
        var memory = WindowMemory()
        let setup = DisplaySetup([displayA])
        for window in [w1, w2, w3] {
            memory.openChain(window, before: rect(100, 100, 400, 300), on: displayA)
            memory.recordPlaced(window, placed())
            memory.recordLastKnown(window, frame: rect(100, 100, 400, 300), display: displayA, setup: setup)
        }
        memory.forget(pid: 100)
        for window in [w1, w2] {
            #expect(memory.placed[window] == nil && memory.restore[window] == nil)
            #expect(memory.lastKnown(window, setup: setup) == nil)
        }
        #expect(memory.placed[w3] != nil && memory.restore[w3] != nil)
        #expect(memory.lastKnown(w3, setup: setup) != nil)
    }

    @Test func processesGoneOrLaunchedSinceTheSaveAreGone() {
        let saved = Date(timeIntervalSince1970: 1_800_000_000)
        let w4 = WindowHandle(pid: 300, windowID: 1, isStable: true)
        var memory = WindowMemory(savedAt: saved)
        memory.recordPlaced(w1, placed())
        memory.openChain(w3, before: rect(100, 100, 400, 300), on: displayA)
        memory.recordLastKnown(w4, frame: rect(100, 100, 400, 300), display: displayA, setup: DisplaySetup([displayA]))
        #expect(memory.windowPids == [100, 200, 300])
        // 100 ran before the save; 200 was launched after it; 300 is not running.
        let launched: [Int32: Date] = [100: saved.addingTimeInterval(-1), 200: saved.addingTimeInterval(1)]
        #expect(memory.goneProcesses(launched: launched) == [200, 300])
    }

    @Test func withoutASaveDateNoProcessIsKnownToBeTheSame() {
        var memory = WindowMemory()
        memory.recordPlaced(w1, placed())
        memory.recordPlaced(w3, placed())
        #expect(memory.goneProcesses(launched: [100: .distantPast, 200: .distantPast]) == [100, 200])
    }

    @Test func forgettingProcessesRemovesTheirWindowsEverywhere() {
        var memory = WindowMemory()
        let setup = DisplaySetup([displayA])
        for window in [w1, w3] {
            memory.openChain(window, before: rect(100, 100, 400, 300), on: displayA)
            memory.recordPlaced(window, placed())
            memory.recordLastKnown(window, frame: rect(100, 100, 400, 300), display: displayA, setup: setup)
        }
        memory.forget(pids: [200])
        #expect(memory.windowPids == [100])
        #expect(memory.placed[w1] != nil && memory.restore[w1] != nil && memory.lastKnown(w1, setup: setup) != nil)
    }

    @Test func forgettingTheLastWindowOfASetupDropsTheSetup() {
        var memory = WindowMemory()
        memory.recordLastKnown(w1, frame: rect(100, 100, 400, 300), display: displayA, setup: DisplaySetup([displayA]))
        memory.recordLastKnown(w3, frame: rect(100, 100, 400, 300), display: displayA, setup: DisplaySetup([displayA, displayB]))
        memory.forget(w1)
        #expect(memory.lastKnown[DisplaySetup([displayA])] == nil)
        memory.forget(pid: 200)
        #expect(memory.lastKnown.isEmpty)
    }
}
