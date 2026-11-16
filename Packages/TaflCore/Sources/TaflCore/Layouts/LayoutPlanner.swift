public enum LayoutPlanner {
    public static func entryIndex(for window: WindowSnapshot, in layout: LayoutDefinition) -> Int? {
        layout.entries.firstIndex { entry in
            entry.app == window.bundleID && entry.title.map { TitleGlob.matches($0, window.title) } ?? true
        }
    }

    public static func requests(
        _ layout: LayoutDefinition,
        windows: [WindowSnapshot],
        displays: [Display],
        source: RequestSource
    ) -> [MoveRequest] {
        windows.compactMap { window in
            guard window.isPlaceable,
                  let index = entryIndex(for: window, in: layout)
            else { return nil }
            let entry = layout.entries[index]
            guard let display = display(for: entry, in: layout, window: window, displays: displays) else { return nil }
            return MoveRequest(
                window: window.handle,
                spec: .named(entry.place),
                display: display.identity,
                placement: entry.place,
                cycleStep: 0,
                source: source
            )
        }
    }

    /// The windows to bring to the front, in the order to raise them: the last entry's first, so the
    /// first entry's windows end on top, and within an entry the window that was in front last, so it
    /// stays in front. `windows` are in front-to-back order for each app, as the platform lists them.
    public static func raiseOrder(
        _ layout: LayoutDefinition,
        windows: [WindowSnapshot],
        among raisable: Set<WindowHandle>
    ) -> [WindowHandle] {
        var byEntry: [Int: [WindowHandle]] = [:]
        for window in windows where raisable.contains(window.handle) {
            guard let index = entryIndex(for: window, in: layout) else { continue }
            byEntry[index, default: []].append(window.handle)
        }
        return layout.entries.indices.reversed().flatMap { (byEntry[$0] ?? []).reversed() }
    }

    public static func claiming(_ layouts: [LayoutDefinition], displays: [Display]) -> LayoutDefinition? {
        layouts.first { !$0.displays.isEmpty && DisplayMatcher.claims($0.displays, displays) }
    }

    private static func display(
        for entry: LayoutEntry,
        in layout: LayoutDefinition,
        window: WindowSnapshot,
        displays: [Display]
    ) -> Display? {
        let reference = entry.display ?? (layout.displays.count == 1 ? layout.displays[0] : nil)
        if let reference, let named = DisplayMatcher.display(for: reference, in: displays) {
            return named
        }
        return DisplayLocator.display(containing: window.frame, in: displays)
    }
}
