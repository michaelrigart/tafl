import Foundation
import Testing
@testable import TaflCore

private let early = Date(timeIntervalSince1970: 100)
private let late = Date(timeIntervalSince1970: 200)

@Test func aCopyDefersToOneThatStartedEarlier() {
    #expect(InstanceOrder.defers(own: (late, 20), to: (early, 90)))
}

@Test func aCopyDoesNotDeferToOneThatStartedLater() {
    #expect(!InstanceOrder.defers(own: (early, 90), to: (late, 20)))
}

@Test func copiesStartedTogetherSettleOnTheLowerPid() {
    #expect(InstanceOrder.defers(own: (early, 30), to: (early, 20)))
    #expect(!InstanceOrder.defers(own: (early, 20), to: (early, 30)))
}

@Test func anUnknownLaunchDateFallsBackToThePid() {
    #expect(InstanceOrder.defers(own: (nil, 30), to: (early, 20)))
    #expect(!InstanceOrder.defers(own: (early, 20), to: (nil, 30)))
}
