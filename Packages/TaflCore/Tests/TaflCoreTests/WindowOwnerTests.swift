import Foundation
import Testing
@testable import TaflCore

private let handle = WindowHandle(pid: 100, windowID: 1, isStable: true)
private let start = rect(100, 100, 400, 300)
private let leftHalf = rect(0, 25, 500, 775)
private let dragged = rect(300, 300, 400, 300)
private let onlyA = DisplaySetup([displayA])

private func reading(_ frame: ScreenRect, of window: WindowHandle = handle) -> WindowSnapshot {
    var snapshot = TaflCoreTests.window(window.windowID, frame: frame, pid: window.pid)
    snapshot.handle = window
    return snapshot
}

private func placedLeftHalf() -> PlacedRecord {
    PlacedRecord(action: .leftHalf, layout: nil, placement: .leftHalf, cycleStep: 0, achieved: leftHalf, display: displayA.identity)
}

/// What a request that wrote the left half and found it placed has to record.
private func placedByLeftHalf() -> Applied {
    .wrote(.placed(leftHalf), leftHalfRequest(for: handle), displays: [displayA], fallback: displayA)
}

/// The window placed at the left half by a request that began at `start`, its chain open.
private func placedOwner() -> WindowOwner {
    let owner = WindowOwner(adjustments: MacOSAdjustment.measured27)
    owner.recordLastKnown(for: [displayA])
    let request = owner.beginRequest(reading(start))
    let sized = rect(100, 100, 500, 775)
    #expect(owner.willWrite(request.ticket, .size, targetVisible: v, displays: [displayA], firstWrite: FirstWrite(opensChainOn: displayA)) == .write)
    #expect(owner.readBack(request.ticket, sized) == .own(sized))
    #expect(owner.willWrite(request.ticket, .position, targetVisible: v, displays: [displayA], firstWrite: FirstWrite()) == .write)
    #expect(owner.readBack(request.ticket, leftHalf) == .own(leftHalf))
    owner.endRequest(request.ticket, recording: placedByLeftHalf())
    return owner
}

private func lastKnown(_ owner: WindowOwner, _ setup: DisplaySetup = onlyA) -> UnitRect? {
    owner.windowMemory.lastKnown(handle, setup: setup)?.relative
}

// MARK: Readings

@Test func aFirstReadingIsNoMove() {
    let owner = WindowOwner(adjustments: [])
    #expect(owner.read(reading(start)) == .first)
    #expect(!owner.isTouched(handle))
    #expect(owner.read(reading(start)) == .own)
    #expect(owner.read(reading(dragged)) == .external)
    #expect(owner.isTouched(handle))
}

@Test func aFirstReadingAwayFromAPlacedRecordFromDiskUndoesItWithoutATouch() {
    var saved = WindowMemory()
    saved.openChain(handle, before: start, on: displayA)
    saved.recordPlaced(handle, placedLeftHalf())

    let atIt = WindowOwner(adjustments: [])
    atIt.loadWindows(from: saved)
    #expect(atIt.read(reading(leftHalf)) == .first)
    #expect(atIt.windowMemory.placed[handle] == placedLeftHalf())
    #expect(atIt.windowMemory.restore[handle]?.chainOpen == true)

    let away = WindowOwner(adjustments: [])
    away.loadWindows(from: saved)
    #expect(away.read(reading(dragged)) == .first)
    #expect(away.windowMemory.placed[handle] == nil)
    #expect(away.windowMemory.restore[handle]?.chainOpen == false)
    #expect(!away.isTouched(handle))
}

@Test func anExternalReadingRecordsItsChangeInTheSameStep() {
    let owner = placedOwner()
    #expect(owner.windowMemory.restore[handle]?.chainOpen == true)
    #expect(owner.read(reading(dragged)) == .external)
    // Nothing in between: the step that judged the move recorded it.
    #expect(owner.windowMemory.placed[handle] == nil)
    #expect(owner.windowMemory.restore[handle]?.chainOpen == false)
    #expect(owner.isTouched(handle))
    #expect(lastKnown(owner) == dragged.relative(to: v))
    // A newer reading at the same frame is no move, and leaves the change recorded.
    #expect(owner.read(reading(dragged)) == .own)
    #expect(owner.windowMemory.restore[handle]?.chainOpen == false)
}

// MARK: The expected frame

/// The left half, moved `dx` points across.
private func leftHalf(nudgedBy dx: Double) -> ScreenRect {
    rect(leftHalf.x + dx, leftHalf.y, leftHalf.width, leftHalf.height)
}

@Test func twoOnePointMovesOutsideARequestAddUpToAnExternalChange() {
    let owner = placedOwner()
    #expect(owner.read(reading(leftHalf(nudgedBy: 1))) == .own)
    // Judged against the frame achieved, not the newest reading.
    #expect(owner.read(reading(leftHalf(nudgedBy: 2))) == .external)
    #expect(owner.isTouched(handle))
    #expect(owner.windowMemory.placed[handle] == nil)
    #expect(owner.windowMemory.restore[handle]?.chainOpen == false)
    // The next placement starts a new chain where the window drifted to.
    let next = owner.beginRequest(reading(leftHalf(nudgedBy: 2)))
    #expect(owner.willWrite(next.ticket, .position, targetVisible: v, displays: [displayA], firstWrite: FirstWrite(opensChainOn: displayA)) == .write)
    #expect(owner.windowMemory.restore[handle]?.frame == leftHalf(nudgedBy: 2))
}

@Test func readingsWithinAPointOfTheFrameAchievedNeverBecomeExternal() {
    let owner = placedOwner()
    for dx in [1.0, 1, 1, -1, 1, -1, 0] {
        #expect(owner.read(reading(leftHalf(nudgedBy: dx))) == .own, "\(dx)")
    }
    #expect(!owner.isTouched(handle))
    #expect(owner.windowMemory.placed[handle] == placedLeftHalf())
    #expect(owner.windowMemory.restore[handle]?.chainOpen == true)
}

@Test func betweenARequestsWritesSmallMovesAddUpToo() {
    let owner = WindowOwner(adjustments: [])
    let request = owner.beginRequest(reading(start))
    let sized = rect(100, 100, 500, 775)
    #expect(owner.willWrite(request.ticket, .size, targetVisible: v, displays: [displayA], firstWrite: FirstWrite()) == .write)
    #expect(owner.readBack(request.ticket, sized) == .own(sized))
    // Nothing in flight: each reading is judged against what the write achieved.
    #expect(owner.read(reading(rect(101, 100, 500, 775))) == .own)
    #expect(owner.read(reading(rect(102, 100, 500, 775))) == .external)
    #expect(owner.checkpoint(request.ticket) == .interrupted)
}

@Test func aPlacedRecordFromDiskIsTheFrameExpectedWhileTheWindowIsAtIt() {
    var saved = WindowMemory()
    saved.openChain(handle, before: start, on: displayA)
    saved.recordPlaced(handle, placedLeftHalf())
    let owner = WindowOwner(adjustments: [])
    owner.loadWindows(from: saved)

    #expect(owner.read(reading(leftHalf(nudgedBy: 1))) == .first)
    #expect(owner.read(reading(leftHalf(nudgedBy: -1))) == .own)
    #expect(owner.read(reading(leftHalf(nudgedBy: 2))) == .external)
    #expect(owner.windowMemory.placed[handle] == nil)
    #expect(owner.windowMemory.restore[handle]?.chainOpen == false)
}

@Test func aRequestsOwnReadsSetTheFrameItExpects() {
    // Resolve's reading: a request that finds the window already in place achieved that frame.
    let unchanged = placedOwner()
    let resolved = leftHalf(nudgedBy: 1)
    let request = unchanged.beginRequest(reading(resolved))
    unchanged.endRequest(request.ticket, recording: .unchanged(leftHalfRequest(for: handle), frame: resolved, display: displayA))
    #expect(unchanged.windowMemory.placed[handle]?.achieved == resolved)
    #expect(unchanged.read(reading(leftHalf(nudgedBy: 2))) == .own)

    // A read with nothing in flight, as the reapply's first: the request goes on from what it read.
    let reapplied = WindowOwner(adjustments: [])
    let second = reapplied.beginRequest(reading(start))
    #expect(reapplied.willWrite(second.ticket, .position, targetVisible: v, displays: [displayA], firstWrite: FirstWrite()) == .write)
    #expect(reapplied.readBack(second.ticket, rect(0, 25, 400, 300)) == .own(rect(0, 25, 400, 300)))
    #expect(reapplied.readBack(second.ticket, rect(1, 25, 400, 300)) == .own(rect(1, 25, 400, 300)))
    #expect(reapplied.read(reading(rect(2, 25, 400, 300))) == .own)
    #expect(reapplied.checkpoint(second.ticket) == .write)
}

@Test func lastKnownFramesAreRecordedForTheDisplaysCurrentAtTheReading() {
    let owner = WindowOwner(adjustments: [])
    owner.recordLastKnown(for: [displayA])
    owner.read(reading(start))
    #expect(lastKnown(owner) == start.relative(to: v))

    // From the start of a change, nothing is recorded.
    owner.reconfigurationBegan()
    owner.read(reading(dragged))
    #expect(lastKnown(owner) == start.relative(to: v))

    // Once the new setup is settled, readings are recorded for it.
    let docked = [displayA, displayB]
    owner.recordLastKnown(for: docked)
    let onB = rect(1100, 100, 400, 300)
    owner.read(reading(onB))
    #expect(owner.windowMemory.lastKnown(handle, setup: DisplaySetup(docked)) == StoredFrame(
        display: displayB.identity, relative: onB.relative(to: displayB.visibleFrame)
    ))

    // An app whose moves are not observed, and a window that can't be placed, record nothing.
    owner.leaveOut(pids: [handle.pid])
    owner.read(reading(rect(1200, 100, 400, 300)))
    owner.leaveOut(pids: [])
    var minimised = reading(rect(1300, 100, 400, 300))
    minimised.isMinimized = true
    owner.read(minimised)
    #expect(owner.windowMemory.lastKnown(handle, setup: DisplaySetup(docked))?.relative == onB.relative(to: displayB.visibleFrame))
}

// MARK: Requests

@Test func resolveFindingAMoveClosesTheChainAndTheRequestStartsThere() {
    let owner = placedOwner()
    let request = owner.beginRequest(reading(dragged))
    #expect(request.placement.placed == nil)
    #expect(request.placement.restore?.chainOpen == false)
    #expect(owner.isTouched(handle))
    // The move came before the request: it goes on, and its first write opens a chain at the dragged frame.
    #expect(owner.willWrite(request.ticket, .position, targetVisible: v, displays: [displayA], firstWrite: FirstWrite(opensChainOn: displayA)) == .write)
    #expect(owner.windowMemory.restore[handle] == RestoreRecord(frame: dragged, display: displayA.identity, visibleFrame: v, chainOpen: true))
}

@Test func aMoveAfterResolveInterruptsTheRequestAndOutlivesItsEnd() {
    let owner = placedOwner()
    let request = owner.beginRequest(reading(leftHalf))
    #expect(owner.read(reading(dragged)) == .external)
    #expect(owner.read(reading(dragged)) == .own)
    #expect(owner.checkpoint(request.ticket) == .interrupted)
    #expect(owner.willWrite(request.ticket, .size, targetVisible: v, displays: [displayA], firstWrite: FirstWrite()) == .interrupted)
    let ending = owner.endRequest(request.ticket)
    #expect(ending == RequestEnding(interrupted: true, wrote: false))
    #expect(owner.windowMemory.placed[handle] == nil)
    #expect(owner.windowMemory.restore[handle]?.chainOpen == false)
}

@Test func whileAWriteIsInFlightItsPartMayDifferAndTheOtherMustNot() {
    let owner = WindowOwner(adjustments: [])
    let request = owner.beginRequest(reading(start))
    #expect(owner.willWrite(request.ticket, .size, targetVisible: v, displays: [displayA], firstWrite: FirstWrite()) == .write)
    #expect(owner.read(reading(rect(100, 100, 450, 300))) == .own)
    #expect(owner.readBack(request.ticket, rect(100, 100, 500, 775)) == .own(rect(100, 100, 500, 775)))
    // Read back, the size is no longer in flight.
    #expect(owner.read(reading(rect(100, 100, 480, 775))) == .external)
    #expect(owner.checkpoint(request.ticket) == .interrupted)
}

@Test func afterAFailedWriteNothingIsInFlight() {
    let owner = WindowOwner(adjustments: [])
    let request = owner.beginRequest(reading(start))
    #expect(owner.willWrite(request.ticket, .position, targetVisible: v, displays: [displayA], firstWrite: FirstWrite()) == .write)
    owner.writeFailed(request.ticket)
    #expect(owner.read(reading(start)) == .own)
    #expect(owner.read(reading(rect(0, 25, 400, 300))) == .external)
}

@Test func aReadingInFlightIsCheckedAsTheReadBackAndSetsTheFrameExpected() {
    let owner = WindowOwner(adjustments: [])
    let request = owner.beginRequest(reading(start))
    #expect(owner.willWrite(request.ticket, .position, targetVisible: v, displays: [displayA], firstWrite: FirstWrite()) == .write)
    let written = rect(0, 25, 400, 300)
    #expect(owner.read(reading(written)) == .own)
    // The write's own read never came: the frame the event read is still Tafl's.
    owner.writeFailed(request.ticket)
    #expect(owner.read(reading(written)) == .own)
    #expect(owner.read(reading(start)) == .external)
}

@Test func aRequestBegunBeforeAReconfigurationWritesNothing() {
    let owner = WindowOwner(adjustments: [])
    let earlier = owner.beginRequest(reading(start))
    owner.reconfigurationBegan()
    #expect(owner.willWrite(earlier.ticket, .size, targetVisible: v, displays: [displayA], firstWrite: FirstWrite()) == .cancelled)
    owner.endRequest(earlier.ticket)
    let later = owner.beginRequest(reading(start))
    #expect(owner.willWrite(later.ticket, .size, targetVisible: v, displays: [displayA], firstWrite: FirstWrite()) == .write)
}

@Test func theFirstWriteOfARequestThatYieldsDeclinesForATouchedWindow() {
    let owner = WindowOwner(adjustments: [])
    let request = owner.beginRequest(reading(start))
    owner.touch(handle)
    let yields = FirstWrite(opensChainOn: displayA, yieldsToTouch: true)
    #expect(owner.willWrite(request.ticket, .size, targetVisible: v, displays: [displayA], firstWrite: yields) == .declined)
    #expect(owner.windowMemory.restore[handle] == nil)
    #expect(owner.endRequest(request.ticket) == RequestEnding(interrupted: false, wrote: false))
}

@Test func theFirstCheckpointOfARequestThatYieldsDeclinesATouchedWindowButALaterOneDoesNot() {
    let owner = WindowOwner(adjustments: [])
    let request = owner.beginRequest(reading(start))
    let yields = FirstWrite(yieldsToTouch: true)
    #expect(owner.checkpoint(request.ticket, firstWrite: yields) == .write)
    #expect(owner.willWrite(request.ticket, .size, targetVisible: v, displays: [displayA], firstWrite: yields) == .write)
    // Once the first write has begun, a touch no longer stops the request.
    owner.touch(handle)
    #expect(owner.checkpoint(request.ticket, firstWrite: yields) == .write)
    owner.endRequest(request.ticket)

    let touched = owner.beginRequest(reading(start))
    #expect(owner.checkpoint(touched.ticket, firstWrite: yields) == .declined)
    #expect(owner.checkpoint(touched.ticket) == .write)
}

// MARK: Lifetimes

@Test func aDestroyedWindowLeavesNothingAndItsIDStartsFresh() {
    let owner = placedOwner()
    #expect(owner.read(reading(dragged)) == .external)
    let request = owner.beginRequest(reading(dragged))
    owner.destroyed(handle)
    #expect(!owner.knows(handle))
    #expect(!owner.windowMemory.holdsWindow { $0 == handle })
    // The request it had records nothing when it ends.
    let ending = owner.endRequest(request.ticket, recording: placedByLeftHalf())
    #expect(ending == RequestEnding(interrupted: false, wrote: false))
    #expect(owner.windowMemory.placed[handle] == nil)
    // A window that gets the id is new: its first reading is no move, and nothing is touched.
    #expect(owner.read(reading(start)) == .first)
    #expect(!owner.isTouched(handle))
}

@Test func aQuitAppLeavesNothingOfItsWindows() {
    let owner = placedOwner()
    let other = WindowHandle(pid: 200, windowID: 1, isStable: true)
    owner.read(reading(start, of: other))
    owner.quit(pid: handle.pid)
    #expect(!owner.knows(handle))
    #expect(!owner.windowMemory.holdsWindow { $0.pid == handle.pid })
    #expect(owner.knows(other))
}

// MARK: Creation

@Test func aWindowIsPlacedAtCreationOnlyWhenItsAnnouncementIsItsFirstReading() {
    let announcedFirst = WindowOwner(adjustments: [])
    announcedFirst.announced(reading(start))
    #expect(announcedFirst.placesAtCreation(handle))
    // Answered once.
    #expect(!announcedFirst.placesAtCreation(handle))

    let readFirst = WindowOwner(adjustments: [])
    readFirst.read(reading(start))
    readFirst.announced(reading(start))
    #expect(!readFirst.placesAtCreation(handle))

    let touchedFirst = WindowOwner(adjustments: [])
    touchedFirst.announced(reading(start))
    touchedFirst.touch(handle)
    #expect(!touchedFirst.placesAtCreation(handle))
}
