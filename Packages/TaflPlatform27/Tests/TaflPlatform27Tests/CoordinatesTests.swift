import CoreGraphics
import Testing
@testable import TaflPlatform27

@Test func flipsBetweenAppKitAndAX() {
    let primaryHeight: CGFloat = 982

    let builtIn = Coordinates27.AppKitRect(CGRect(x: 0, y: 0, width: 1512, height: 957))
    let builtInAX = Coordinates27.toAX(builtIn, primaryHeight: primaryHeight)
    #expect(builtInAX.rect == CGRect(x: 0, y: 25, width: 1512, height: 957))
    #expect(Coordinates27.toAppKit(builtInAX, primaryHeight: primaryHeight) == builtIn)

    let above = Coordinates27.AppKitRect(CGRect(x: 0, y: 982, width: 2560, height: 1440))
    let aboveAX = Coordinates27.toAX(above, primaryHeight: primaryHeight)
    #expect(aboveAX.rect == CGRect(x: 0, y: -1440, width: 2560, height: 1440))
    #expect(Coordinates27.toAppKit(aboveAX, primaryHeight: primaryHeight) == above)
}

@Test func nullRectStaysNullWhenFlipped() {
    let flipped = Coordinates27.toAX(Coordinates27.AppKitRect(.null), primaryHeight: 982)
    #expect(flipped.rect.isNull)
}
