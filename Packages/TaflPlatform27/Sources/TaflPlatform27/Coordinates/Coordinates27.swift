import CoreGraphics

public enum Coordinates27 {
    public struct AppKitRect: Equatable, Sendable {
        public var rect: CGRect
        public init(_ rect: CGRect) { self.rect = rect }
    }

    public struct AXRect: Equatable, Sendable {
        public var rect: CGRect
        public init(_ rect: CGRect) { self.rect = rect }
    }

    public static func toAX(_ rect: AppKitRect, primaryHeight: CGFloat) -> AXRect {
        AXRect(flipped(rect.rect, primaryHeight: primaryHeight))
    }

    public static func toAppKit(_ rect: AXRect, primaryHeight: CGFloat) -> AppKitRect {
        AppKitRect(flipped(rect.rect, primaryHeight: primaryHeight))
    }

    private static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        guard !rect.isNull else { return rect }
        return CGRect(origin: CGPoint(x: rect.origin.x, y: primaryHeight - rect.maxY), size: rect.size)
    }
}
