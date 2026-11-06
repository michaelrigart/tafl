import ApplicationServices
import CoreGraphics
import Testing
import TaflCore
@testable import TaflPlatform27

private let handle = WindowHandle(pid: 10, windowID: 7, isStable: true)
private let app = AppInfo27(pid: 10, bundleID: "com.example.App", name: "Example", isHidden: false)

private func attributes(
    role: String? = "AXWindow",
    subrole: String? = "AXStandardWindow",
    isMinimized: Bool = false,
    isFullscreen: Bool = false
) -> WindowAttributes27 {
    WindowAttributes27(
        role: role, subrole: subrole, title: "Doc", frame: CGRect(x: 10, y: 20, width: 300, height: 200),
        canMove: true, canResize: false, minSize: CGSize(width: 100, height: 50),
        isFullscreen: isFullscreen, isMinimized: isMinimized)
}

@Test func aStandardWindowBecomesASnapshotWithEveryField() {
    let snapshot = Windows27.trackedSnapshot(handle: handle, app: app, attributes: attributes())
    #expect(snapshot == WindowSnapshot(
        handle: handle, bundleID: "com.example.App", appName: "Example", title: "Doc",
        frame: ScreenRect(x: 10, y: 20, width: 300, height: 200),
        canMove: true, canResize: false, minSize: ScreenSize(width: 100, height: 50),
        isFullscreen: false, isSheet: false, isMinimized: false, isAppHidden: false))
}

@Test func aSheetIsKeptAndFlagged() {
    let bySubrole = Windows27.trackedSnapshot(handle: handle, app: app, attributes: attributes(subrole: "AXSheet"))
    let byRole = Windows27.trackedSnapshot(handle: handle, app: app, attributes: attributes(role: "AXSheet", subrole: nil))
    #expect(bySubrole?.isSheet == true)
    #expect(byRole?.isSheet == true)
    #expect(bySubrole?.isPlaceable == false)
}

@Test func windowsThatAreNeitherStandardNorSheetsAreLeftOut() {
    for subrole in ["AXDialog", "AXFloatingWindow", "AXSystemDialog", "AXSystemFloatingWindow", nil] {
        #expect(Windows27.trackedSnapshot(handle: handle, app: app, attributes: attributes(subrole: subrole)) == nil, "\(String(describing: subrole))")
    }
}

@Test func minimizedFullscreenAndHiddenAppFlagsComeThrough() {
    let minimized = Windows27.trackedSnapshot(handle: handle, app: app, attributes: attributes(isMinimized: true))
    let fullscreen = Windows27.trackedSnapshot(handle: handle, app: app, attributes: attributes(isFullscreen: true))
    let hiddenApp = AppInfo27(pid: 10, bundleID: nil, name: "Example", isHidden: true)
    let hidden = Windows27.trackedSnapshot(handle: handle, app: hiddenApp, attributes: attributes())
    #expect(minimized?.isMinimized == true)
    #expect(fullscreen?.isFullscreen == true)
    #expect(hidden?.isAppHidden == true)
    #expect(hidden?.bundleID == nil)
    #expect(hidden?.isPlaceable == false)
}

@Test func anAppWithoutAMinimumSizeGivesNone() {
    var raw = attributes()
    raw.minSize = nil
    #expect(Windows27.trackedSnapshot(handle: handle, app: app, attributes: raw)?.minSize == nil)
}

@Test func accessibilityErrorsMapToTheContractsFailures() {
    #expect(Windows27.failure(for: .cannotComplete) == .notResponding)
    #expect(Windows27.failure(for: .invalidUIElement) == .noWindow)
    #expect(Windows27.failure(for: .noValue) == .noWindow)
    #expect(Windows27.failure(for: .attributeUnsupported) == .noWindow)
}

@Test func theFocusedPathKeepsDialogsPalettesAndWindowsWithoutASubrole() {
    for subrole in ["AXDialog", "AXFloatingWindow", "AXSystemFloatingWindow", nil] {
        let snapshot = Windows27.snapshot(handle: handle, app: app, attributes: attributes(subrole: subrole))
        #expect(snapshot.handle == handle, "\(String(describing: subrole))")
        #expect(!snapshot.isSheet)
    }
}

@Test func theFocusedPathStillFlagsSheets() {
    #expect(Windows27.snapshot(handle: handle, app: app, attributes: attributes(subrole: "AXSheet")).isSheet)
}

@Test func aSystemDialogIsNeverResizable() {
    var raw = attributes(subrole: "AXSystemDialog")
    raw.canResize = true
    #expect(!Windows27.snapshot(handle: handle, app: app, attributes: raw).canResize)
    raw.subrole = "AXDialog"
    #expect(Windows27.snapshot(handle: handle, app: app, attributes: raw).canResize)
}

@Test func aFailedPositionWriteIsFullscreenCannotMoveOrNotRespondingByCause() {
    #expect(Windows27.positionFailure(for: .cannotComplete, isFullscreen: { .success(false) }) == .notResponding)
    #expect(Windows27.positionFailure(for: .invalidUIElement, isFullscreen: { .success(false) }) == .noWindow)
    #expect(Windows27.positionFailure(for: .failure, isFullscreen: { .success(false) }) == .cannotMove)
    #expect(Windows27.positionFailure(for: .failure, isFullscreen: { .success(true) }) == .fullscreen)
}

@Test func aRefusalWhoseFullScreenCheckGetsNoAnswerIsNotRespondingOrNoWindow() {
    #expect(Windows27.positionFailure(for: .failure, isFullscreen: { .failure(AXFailure(.cannotComplete)) }) == .notResponding)
    #expect(Windows27.positionFailure(for: .failure, isFullscreen: { .failure(AXFailure(.invalidUIElement)) }) == .noWindow)
    #expect(position(settable: .success(false), fullscreen: .failure(AXFailure(.cannotComplete))).failure == .notResponding)
}

private func position(
    settable: Result<Bool, AXFailure>, write: AXError = .success, fullscreen: Result<Bool, AXFailure> = .success(false)
) -> (failure: PlatformFailure?, wrote: Bool) {
    var wrote = false
    let result = Windows27.writePosition(
        settable: { settable }, write: { wrote = true; return write }, isFullscreen: { fullscreen })
    if case .failure(let failure) = result { return (failure, wrote) }
    return (nil, wrote)
}

private func lookUp(
    focused: () -> Result<Int, AXFailure>, first: () -> Result<Int?, AXFailure>, systemWide: () -> Result<Int?, AXFailure>
) -> Result<Int, AXFailure> {
    AXWindowAccess.lookUpFocusedWindow(focused: focused, first: first, systemWide: systemWide)
}

@Test func aTimeoutReadingSettabilityIsNotRespondingNotCannotMove() {
    let outcome = position(settable: .failure(AXFailure(.cannotComplete)))
    #expect(outcome.failure == .notResponding)
    #expect(!outcome.wrote)
}

@Test func aTimeoutWritingThePositionIsNotResponding() {
    let outcome = position(settable: .success(true), write: .cannotComplete)
    #expect(outcome.failure == .notResponding)
    #expect(outcome.wrote)
}

@Test func aDestroyedWindowIsNoWindowAtEitherStep() {
    #expect(position(settable: .failure(AXFailure(.invalidUIElement))).failure == .noWindow)
    #expect(position(settable: .success(true), write: .invalidUIElement).failure == .noWindow)
}

@Test func aGenuineRefusalIsFullscreenOrCannotMove() {
    let unsettable = position(settable: .success(false))
    #expect(unsettable.failure == .cannotMove)
    #expect(!unsettable.wrote)
    #expect(position(settable: .success(false), fullscreen: .success(true)).failure == .fullscreen)
    #expect(position(settable: .success(true), write: .failure).failure == .cannotMove)
    #expect(position(settable: .success(true), write: .failure, fullscreen: .success(true)).failure == .fullscreen)
}

@Test func aSettableWindowIsWritten() {
    let outcome = position(settable: .success(true))
    #expect(outcome.failure == nil)
    #expect(outcome.wrote)
}

@Test func aSettabilityFailureOtherThanATimeoutIsARefusal() {
    #expect(position(settable: .failure(AXFailure(.attributeUnsupported))).failure == .cannotMove)
}

@Test func theFocusedLookupStopsAtTheFirstTimeout() {
    var calls: [String] = []
    let result = lookUp(
        focused: { calls.append("focused"); return .failure(AXFailure(.cannotComplete)) },
        first: { calls.append("first"); return .success(1) },
        systemWide: { calls.append("systemWide"); return .success(2) })
    #expect(result == .failure(AXFailure(.cannotComplete)))
    #expect(calls == ["focused"])
}

@Test func theFocusedLookupStopsAtATimeoutInTheWindowList() {
    var calls: [String] = []
    let result = lookUp(
        focused: { calls.append("focused"); return .failure(AXFailure(.noValue)) },
        first: { calls.append("first"); return .failure(AXFailure(.cannotComplete)) },
        systemWide: { calls.append("systemWide"); return .success(2) })
    #expect(result == .failure(AXFailure(.cannotComplete)))
    #expect(calls == ["focused", "first"])
}

@Test func theFocusedLookupStopsAtATimeoutInTheSystemWideLookup() {
    let failed = lookUp(focused: { .failure(AXFailure(.noValue)) }, first: { .success(nil) }, systemWide: { .failure(AXFailure(.cannotComplete)) })
    #expect(failed == .failure(AXFailure(.cannotComplete)))
    let gone = lookUp(focused: { .failure(AXFailure(.noValue)) }, first: { .success(nil) }, systemWide: { .failure(AXFailure(.invalidUIElement)) })
    #expect(gone == .failure(AXFailure(.noValue)))
}

@Test func theFocusedLookupFallsThroughOrdinaryFailuresInOrder() {
    #expect(lookUp(
        focused: { .failure(AXFailure(.noValue)) }, first: { .success(1) }, systemWide: { .success(2) }) == .success(1))
    #expect(lookUp(
        focused: { .failure(AXFailure(.noValue)) }, first: { .success(nil) }, systemWide: { .success(2) }) == .success(2))
    #expect(lookUp(
        focused: { .failure(AXFailure(.noValue)) }, first: { .success(nil) }, systemWide: { .success(nil) }) == .failure(AXFailure(.noValue)))
    #expect(lookUp(
        focused: { .success(0) }, first: { .success(1) }, systemWide: { .success(2) }) == .success(0))
}

@Test func aRefusedSizeIsLeftToTheCoresReadBack() {
    #expect(Windows27.sizeFailure(for: .success) == nil)
    #expect(Windows27.sizeFailure(for: .failure) == nil)
    #expect(Windows27.sizeFailure(for: .attributeUnsupported) == nil)
    #expect(Windows27.sizeFailure(for: .cannotComplete) == .notResponding)
    #expect(Windows27.sizeFailure(for: .invalidUIElement) == .noWindow)
}

@Test func windowIdentityCapabilityNamesItsSource() {
    let direct = Platform27.windowIdentityCapability(privateSymbol: true, windowList: true)
    let fallback = Platform27.windowIdentityCapability(privateSymbol: false, windowList: true)
    let none = Platform27.windowIdentityCapability(privateSymbol: false, windowList: false)
    #expect(direct.isAvailable && fallback.isAvailable && !none.isAvailable)
    #expect(Set([direct.note, fallback.note, none.note]).count == 3)
    #expect(direct.name == fallback.name && fallback.name == none.name)
}

// MARK: A window's attributes

/// One query: of which element, for which attribute.
private struct Query: Hashable {
    var element: String
    var attribute: String

    init(_ element: String, _ attribute: String) {
        self.element = element
        self.attribute = attribute
    }
}

/// A standard window "w", whose full-screen button is "b", in an app that answers every query a read
/// makes. A query it has no answer for fails as unsupported, as a missing attribute does.
private struct AnsweringWindow {
    var frame: Result<CGRect, AXFailure> = .success(CGRect(x: 10, y: 20, width: 300, height: 200))
    var strings: [Query: Result<String, AXFailure>] = [
        Query("w", "AXRole"): .success("AXWindow"),
        Query("w", "AXSubrole"): .success("AXStandardWindow"),
        Query("w", "AXTitle"): .success("Doc"),
        Query("b", "AXSubrole"): .success("AXFullScreenButton"),
    ]
    var elements: [Query: Result<String, AXFailure>] = [Query("w", "AXFullScreenButton"): .success("b")]
    var bools: [Query: Result<Bool, AXFailure>] = [
        Query("w", "AXMinimized"): .success(false),
        Query("w", "AXFullScreen"): .success(false),
    ]
    var sizes: [Query: Result<CGSize, AXFailure>] = [Query("w", "AXMinSize"): .success(CGSize(width: 100, height: 50))]
    var settable: [Query: Result<Bool, AXFailure>] = [
        Query("w", "AXPosition"): .success(true),
        Query("w", "AXSize"): .success(true),
    ]

    var queries: WindowQueries27<String> {
        let missing = AXFailure(.attributeUnsupported)
        return WindowQueries27(
            frame: { _ in frame },
            string: { strings[Query($0, $1)] ?? .failure(missing) },
            element: { elements[Query($0, $1)] ?? .failure(missing) },
            bool: { bools[Query($0, $1)] ?? .failure(missing) },
            size: { sizes[Query($0, $1)] ?? .failure(missing) },
            settable: { settable[Query($0, $1)] ?? .failure(missing) })
    }

    func read() -> Result<WindowAttributes27, AXFailure> {
        Windows27.attributes(of: "w", asking: queries)
    }

    /// The same queries, each noted as it is asked: `"<kind> <element>.<attribute>"`.
    func queries(noting asked: QueryLog) -> WindowQueries27<String> {
        let answer = queries
        return WindowQueries27(
            frame: { asked.note("frame \($0)"); return answer.frame($0) },
            string: { asked.note("string \($0).\($1)"); return answer.string($0, $1) },
            element: { asked.note("element \($0).\($1)"); return answer.element($0, $1) },
            bool: { asked.note("bool \($0).\($1)"); return answer.bool($0, $1) },
            size: { asked.note("size \($0).\($1)"); return answer.size($0, $1) },
            settable: { asked.note("settable \($0).\($1)"); return answer.settable($0, $1) })
    }

    func read(noting asked: QueryLog) -> Result<WindowAttributes27, AXFailure> {
        Windows27.attributes(of: "w", asking: queries(noting: asked))
    }
}

private final class QueryLog {
    private(set) var entries: [String] = []
    func note(_ entry: String) { entries.append(entry) }
}

/// Each query a read of "w" makes after its frame, with the window set up so the read asks it.
private enum Asked: CaseIterable {
    case role, subrole, containingWindow, title, positionSettable, sizeSettable
    case minSize, minimumSize, fullScreenButton, buttonSubrole, fullScreenAttribute, minimized

    /// The queries whose failure changes the one Tafl reports: whether the window can be moved or resized.
    static let settability: [Asked] = [.positionSettable, .sizeSettable]
    /// The queries that only refine a read.
    static let optional = allCases.filter { !settability.contains($0) }

    func window(failingWith code: AXError) -> AnsweringWindow {
        var window = AnsweringWindow()
        let failure = AXFailure(code)
        switch self {
        case .role: window.strings[Query("w", "AXRole")] = .failure(failure)
        case .subrole: window.strings[Query("w", "AXSubrole")] = .failure(failure)
        case .containingWindow:
            // Asked only of an element that is not itself a window.
            window.strings[Query("w", "AXRole")] = .success("AXTextField")
            window.elements[Query("w", "AXWindow")] = .failure(failure)
        case .title: window.strings[Query("w", "AXTitle")] = .failure(failure)
        case .positionSettable: window.settable[Query("w", "AXPosition")] = .failure(failure)
        case .sizeSettable: window.settable[Query("w", "AXSize")] = .failure(failure)
        case .minSize: window.sizes[Query("w", "AXMinSize")] = .failure(failure)
        case .minimumSize:
            // Asked only when the window has no AXMinSize.
            window.sizes[Query("w", "AXMinSize")] = nil
            window.sizes[Query("w", "AXMinimumSize")] = .failure(failure)
        case .fullScreenButton: window.elements[Query("w", "AXFullScreenButton")] = .failure(failure)
        case .buttonSubrole: window.strings[Query("b", "AXSubrole")] = .failure(failure)
        case .fullScreenAttribute:
            // Asked only when the button test can't tell.
            window.elements[Query("w", "AXFullScreenButton")] = nil
            window.bools[Query("w", "AXFullScreen")] = .failure(failure)
        case .minimized: window.bools[Query("w", "AXMinimized")] = .failure(failure)
        }
        return window
    }
}

@Test func aReadKeepsEveryAnswer() {
    #expect(AnsweringWindow().read() == .success(WindowAttributes27(
        role: "AXWindow", subrole: "AXStandardWindow", title: "Doc", frame: CGRect(x: 10, y: 20, width: 300, height: 200),
        canMove: true, canResize: true, minSize: CGSize(width: 100, height: 50), isFullscreen: false, isMinimized: false)))

    var zoomed = AnsweringWindow()
    zoomed.strings[Query("b", "AXSubrole")] = .success("AXZoomButton")
    #expect((try? zoomed.read().get())?.isFullscreen == true)
    var flagged = AnsweringWindow()
    flagged.elements[Query("w", "AXFullScreenButton")] = nil
    flagged.bools[Query("w", "AXFullScreen")] = .success(true)
    #expect((try? flagged.read().get())?.isFullscreen == true)
}

@Test func aSettabilityTimeoutAfterTheFrameIsReadIsNotRespondingNotCannotMove() {
    var window = AnsweringWindow()
    window.settable[Query("w", "AXPosition")] = .failure(AXFailure(.cannotComplete))
    let read = window.read()
    #expect(read == .failure(AXFailure(.cannotComplete)))
    #expect(read.mapError { Windows27.failure(for: $0.code) } == .failure(.notResponding))
}

@Test func aWindowWhoseAppSaysItCannotBeMovedIsReadAsSuch() {
    for answer in [Result<Bool, AXFailure>.success(false), .failure(AXFailure(.attributeUnsupported)), .failure(AXFailure(.failure))] {
        var window = AnsweringWindow()
        window.settable[Query("w", "AXPosition")] = answer
        #expect((try? window.read().get())?.canMove == false, "\(answer)")
    }
}

@Test func anAttributeTheWindowLacksTakesItsDefault() {
    let bare = AnsweringWindow(strings: [:], elements: [:], bools: [:], sizes: [:], settable: [:])
    #expect(bare.read() == .success(WindowAttributes27(
        role: nil, subrole: nil, title: "", frame: CGRect(x: 10, y: 20, width: 300, height: 200),
        canMove: false, canResize: false, minSize: nil, isFullscreen: false, isMinimized: false)))
}

/// A timeout arrives as `cannotComplete`; a window closed during the read gives `invalidUIElement`.
@Test(arguments: Asked.settability)
private func aSettabilityQueryTheAppDoesNotAnswerFailsTheReadAsItsFrameWould(_ asked: Asked) {
    let timedOut = asked.window(failingWith: .cannotComplete).read()
    #expect(timedOut.mapError { Windows27.failure(for: $0.code) } == .failure(.notResponding))
    let gone = asked.window(failingWith: .invalidUIElement).read()
    #expect(gone.mapError { Windows27.failure(for: $0.code) } == .failure(.noWindow))
    // Any other failure is the attribute's absence.
    #expect((try? asked.window(failingWith: .attributeUnsupported).read().get()) != nil)
}

/// An app may answer an optional query with an immediate `cannotComplete`: its windows are read
/// all the same, as if they lacked the attribute. A hung app fails at the settability queries.
@Test(arguments: Asked.optional)
private func anOptionalQueryTakesItsDefaultHoweverItFails(_ asked: Asked) {
    let lacking = asked.window(failingWith: .attributeUnsupported).read()
    #expect((try? lacking.get()) != nil)
    for code in [AXError.cannotComplete, .invalidUIElement, .failure] {
        #expect(asked.window(failingWith: code).read() == lacking, "\(code.rawValue)")
    }
}

@Test func anOptionalQueryThatTimesOutFallsBackAsAMissingOneDoes() {
    var fullScreen = Asked.fullScreenButton.window(failingWith: .cannotComplete)
    fullScreen.bools[Query("w", "AXFullScreen")] = .success(true)
    #expect((try? fullScreen.read().get())?.isFullscreen == true)
    var minimum = Asked.minSize.window(failingWith: .cannotComplete)
    minimum.sizes[Query("w", "AXMinimumSize")] = .success(CGSize(width: 80, height: 40))
    #expect((try? minimum.read().get())?.minSize == CGSize(width: 80, height: 40))
}

@Test func aReadAsksTheQueriesThatCanFailItFirstAndStopsAtTheOneThatDoes() {
    var window = AnsweringWindow()
    window.settable[Query("w", "AXSize")] = .failure(AXFailure(.cannotComplete))
    let asked = QueryLog()
    #expect(window.read(noting: asked) == .failure(AXFailure(.cannotComplete)))
    #expect(asked.entries == ["frame w", "settable w.AXPosition", "settable w.AXSize"])
}

// MARK: The system-wide lookup

/// The app asked about is pid 10, whose window is "w" and text field "t"; "x" belongs to another
/// app, pid 20.
private func systemWideLookUp(
    focusing focused: String,
    in window: AnsweringWindow,
    noting asked: QueryLog
) -> Result<String?, AXFailure> {
    var window = window
    window.elements[Query("system", "AXFocusedUIElement")] = .success(focused)
    let pids: [String: pid_t] = ["w": 10, "t": 10, "x": 20]
    return AXWindowAccess.systemWideFocusedWindow(
        of: 10, systemWide: "system", pidOf: { pids[$0] }, asking: window.queries(noting: asked))
}

@Test func theSystemWideLookupAsksNothingOfAnotherAppsElement() {
    // The other app does not answer: its silence is not the target app's.
    var window = AnsweringWindow()
    window.strings[Query("x", "AXRole")] = .failure(AXFailure(.cannotComplete))
    window.elements[Query("x", "AXWindow")] = .failure(AXFailure(.cannotComplete))
    let asked = QueryLog()
    #expect(systemWideLookUp(focusing: "x", in: window, noting: asked) == .success(nil))
    #expect(asked.entries == ["element system.AXFocusedUIElement"])
}

@Test func theSystemWideLookupFindsTheWindowOfTheAppsFocusedElement() {
    var window = AnsweringWindow()
    window.strings[Query("t", "AXRole")] = .success("AXTextField")
    window.elements[Query("t", "AXWindow")] = .success("w")
    #expect(systemWideLookUp(focusing: "w", in: window, noting: QueryLog()) == .success("w"))
    #expect(systemWideLookUp(focusing: "t", in: window, noting: QueryLog()) == .success("w"))
    // The target app's own silence still stops the lookup.
    window.strings[Query("t", "AXRole")] = .failure(AXFailure(.cannotComplete))
    #expect(systemWideLookUp(focusing: "t", in: window, noting: QueryLog()) == .failure(AXFailure(.cannotComplete)))
}

/// What a refused position write asks before it says "full screen" or "can't move".
@Test func theWritesFullScreenCheckTellsATimeoutFromANo() {
    #expect(AnsweringWindow().queries.fullscreen(of: "w") == .success(false))
    var zoomed = AnsweringWindow()
    zoomed.strings[Query("b", "AXSubrole")] = .success("AXZoomButton")
    #expect(zoomed.queries.fullscreen(of: "w") == .success(true))
    for asked in [Asked.role, .containingWindow, .fullScreenButton, .buttonSubrole, .fullScreenAttribute] {
        #expect(asked.window(failingWith: .cannotComplete).queries.fullscreen(of: "w") == .failure(AXFailure(.cannotComplete)), "\(asked)")
        #expect((try? asked.window(failingWith: .attributeUnsupported).queries.fullscreen(of: "w").get()) == false, "\(asked)")
    }
}
