import Testing
import TaflTestSupport

private func numbers() -> (Collector<Int>, AsyncStream<Int>.Continuation) {
    let (stream, sink) = AsyncStream<Int>.makeStream()
    // Markers are negative, so they never look like a number the test sends.
    return (Collector(stream, marker: { -$0 }), sink)
}

@Test(.timeLimit(.minutes(1))) func nextReturnsTheElementsInOrder() async {
    let (collector, sink) = numbers()
    sink.yield(1)
    sink.yield(2)
    #expect(await collector.next() == 1)
    #expect(await collector.next() == 2)
}

@Test(.timeLimit(.minutes(1))) func nextWithNothingSentFailsAtTheBound() async {
    let (collector, _) = numbers()
    await withKnownIssue("a wait that passes its bound records an issue") {
        #expect(await collector.next(timeout: .milliseconds(50)) == nil)
    }
}

@Test(.timeLimit(.minutes(1))) func aDrainReturnsEverythingSentBeforeItWithoutItsMarker() async {
    let (collector, sink) = numbers()
    sink.yield(1)
    sink.yield(2)
    #expect(await collector.drain(through: { sink.yield($0) }) == [1, 2])
}

@Test(.timeLimit(.minutes(1))) func aSecondDrainCollectsWhatWasSentAfterTheFirst() async {
    let (collector, sink) = numbers()
    // Collection runs beside the test, so one round may win the race by luck; many do not.
    var expected: [Int] = []
    for number in 1...50 {
        expected.append(number)
        sink.yield(number)
        #expect(await collector.drain(through: { sink.yield($0) }) == expected)
    }
}

@Test(.timeLimit(.minutes(1))) func aDrainWhoseMarkerNeverArrivesFailsAtTheBound() async {
    let (collector, sink) = numbers()
    sink.yield(1)
    await withKnownIssue("a wait that passes its bound records an issue") {
        _ = await collector.drain(through: { _ in }, timeout: .milliseconds(50))
    }
}

@Test(.timeLimit(.minutes(1))) func aCollectorSeesItsStreamEndAfterWhatItSent() async {
    let (collector, sink) = numbers()
    sink.yield(1)
    sink.finish()
    #expect(await collector.waitForEnd())
    #expect(collector.all == [1])
}

@Test(.timeLimit(.minutes(1))) func waitingForAStreamThatGoesOnFailsAtTheBound() async {
    let (collector, _) = numbers()
    await withKnownIssue("a wait that passes its bound records an issue") {
        #expect(await collector.waitForEnd(timeout: .milliseconds(50)) == false)
    }
}
