import XCTest

final class MeetingAudioMixBufferTests: XCTestCase {
    func testCombinesSourcesAndKeepsTheUnconsumedTail() throws {
        let buffer = MeetingAudioMixBuffer()
        try [Float(0.1), 0.2, 0.3, 0.4].withUnsafeBufferPointer { try buffer.append($0) }
        var microphone: [Float] = [0.2, 0.2]
        microphone.withUnsafeMutableBufferPointer { buffer.mix(into: $0) }
        XCTAssertEqual(microphone[0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(microphone[1], 0.4, accuracy: 0.0001)
        XCTAssertEqual(buffer.sealAndDrain(), [0.3, 0.4])
    }

    func testLateAudioCannotRecreateStoppedCapture() throws {
        let buffer = MeetingAudioMixBuffer()
        XCTAssertTrue(buffer.sealAndDrain().isEmpty)
        try [Float(0.5)].withUnsafeBufferPointer { try buffer.append($0) }
        XCTAssertTrue(buffer.sealAndDrain().isEmpty)
    }

    func testSilentMacAudioPreservesMicrophoneAndMixingDoesNotClip() throws {
        let buffer = MeetingAudioMixBuffer()
        var microphone: [Float] = [0.4, -0.3]
        microphone.withUnsafeMutableBufferPointer { buffer.mix(into: $0) }
        XCTAssertEqual(microphone, [0.4, -0.3])
        try [Float(0.9), -0.9].withUnsafeBufferPointer { try buffer.append($0) }
        microphone.withUnsafeMutableBufferPointer { buffer.mix(into: $0) }
        XCTAssertEqual(microphone, [1, -1])
    }

    func testOverflowFailsInsteadOfDiscardingUnwrittenAudio() throws {
        let buffer = MeetingAudioMixBuffer(capacity: 3)
        try [Float(0.1), 0.2, 0.3].withUnsafeBufferPointer { try buffer.append($0) }
        XCTAssertThrowsError(try [Float(0.4)].withUnsafeBufferPointer { try buffer.append($0) })
        XCTAssertEqual(buffer.sealAndDrain(), [0.1, 0.2, 0.3])
    }

    func testLongCaptureCompactsWithoutRepeatingAudio() throws {
        let buffer = MeetingAudioMixBuffer(capacity: 10)
        for _ in 0..<100 {
            try [Float(0.1), 0.2, 0.3].withUnsafeBufferPointer { try buffer.append($0) }
            var microphone = [Float](repeating: 0, count: 3)
            microphone.withUnsafeMutableBufferPointer { buffer.mix(into: $0) }
            XCTAssertEqual(microphone, [0.1, 0.2, 0.3])
        }
        XCTAssertTrue(buffer.sealAndDrain().isEmpty)
    }
}
