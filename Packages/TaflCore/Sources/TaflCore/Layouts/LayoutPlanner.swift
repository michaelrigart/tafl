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
            guard !window.isMinimized, !window.isAppHidden, !window.isFullscreen, !window.isSheet,
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
