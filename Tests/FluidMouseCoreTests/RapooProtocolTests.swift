import XCTest
@testable import FluidMouseCore

/// Frames and registers below were measured on a real VT9 Pro (openmouse
/// `rapoo-vt9-pro-testing.md`); they are the contract for the channel.
final class RapooProtocolTests: XCTestCase {
    private let readFrame: [UInt8] = [
        0xA5, 0xA4, 0x04, 0x80, 0x08, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    func testReadFrameMatchesVendor() {
        XCTAssertEqual(RapooProtocol.frameRead(address: 0x880, length: 4), readFrame)
        XCTAssertEqual(RapooProtocol.frameRead(address: 0x880, length: 4).count, 31)
    }

    private func expectFrame(_ frame: [UInt8],
                             connection: UInt8 = 0xA5,
                             command: UInt8, length: Int,
                             address: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(frame.count, 31, file: file, line: line)
        XCTAssertEqual(frame[0], connection, file: file, line: line)
        XCTAssertEqual(frame[1], command, file: file, line: line)
        XCTAssertEqual(frame[2], UInt8(length), file: file, line: line)
        XCTAssertEqual(Int(frame[3]) | Int(frame[4]) << 8 | Int(frame[5]) << 16 | Int(frame[6]) << 24,
                       address, file: file, line: line)
    }

    func testWriteFrameCarriesFullBlock() {
        let frame = RapooProtocol.frameWrite(address: 0x880, block: [0x82, 0x00, 0x82, 0xFF])
        expectFrame(frame, command: 0xA5, length: 4, address: 0x880)
        let payload: [UInt8] = [0x82, 0x00, 0x82, 0xFF]
        XCTAssertEqual(Array(frame[7..<11]), payload)
        XCTAssertTrue(frame.dropFirst(11).allSatisfy { $0 == 0 })
    }

    func testAnswerDecoding() throws {
        var raw = readFrame
        raw[0] = 0x01 // status ok for this command
        raw[1] = 0x00 // 0 for a data block answer
        raw[2] = 0x00 // no battery percentage on a block answer
        raw[4] = 0x82; raw[5] = 0x00; raw[6] = 0x82; raw[7] = 0xFF
        let answer = try RapooProtocol.decodeAnswer(raw, expectedLength: 4)
        XCTAssertEqual(answer.block, [0x82, 0x00, 0x82, 0xFF])
        XCTAssertFalse(answer.isBattery)

        // Same answer with the report id prepended (Windows shape).
        let withID: [UInt8] = [UInt8(RapooProtocol.configReportID)] + raw
        let expectedBlock: [UInt8] = [0x82, 0x00, 0x82, 0xFF]
        XCTAssertEqual(try RapooProtocol.decodeAnswer(withID, expectedLength: 4).block,
                       expectedBlock)
    }

    func testBusyAnswerThrows() {
        var raw = readFrame
        raw[0] = 0x02 // not 0x01 — busy, or the previous command's answer
        XCTAssertThrowsError(try RapooProtocol.decodeAnswer(raw, expectedLength: 4)) { error in
            XCTAssertEqual(error as? RapooProtocol.AnswerError, .statusBusy)
        }
    }

    func testShortAnswerThrows() {
        // Fewer than 3 bytes is not an answer at all.
        XCTAssertThrowsError(try RapooProtocol.decodeAnswer([0x01, 0x00],
                                                            expectedLength: 4)) { error in
            XCTAssertEqual(error as? RapooProtocol.AnswerError, .frameTooShort)
        }
    }

    func testBatteryAnswer() {
        XCTAssertEqual(RapooProtocol.decodeBattery([0x01, 0x01, 0x62]),
                       RapooProtocol.Battery(percent: 98, charging: false))
        XCTAssertEqual(RapooProtocol.decodeBattery([0x01, 0x02, 0x64]),
                       RapooProtocol.Battery(percent: 100, charging: true))
        XCTAssertNil(RapooProtocol.decodeBattery([0x01, 0x01, 0xC8]))
        XCTAssertNil(RapooProtocol.decodeBattery([0x01, 0x00, 0x62])) // not a battery answer
    }

    func testFeatureStatusBattery() {
        // 2a 01 00 00 04 21 50 00 00 62 with and without the report id.
        XCTAssertEqual(RapooProtocol.decodeFeatureStatus(
            [0x2a, 0x01, 0x00, 0x00, 0x04, 0x21, 0x50, 0x00, 0x00, 0x62]), 98)
        XCTAssertEqual(RapooProtocol.decodeFeatureStatus(
            [0x01, 0x00, 0x00, 0x04, 0x21, 0x50, 0x00, 0x00, 0x62]), 98)
        XCTAssertNil(RapooProtocol.decodeFeatureStatus([0x01, 0x00, 0x00, 0x04]))
    }

    func testNotificationParsing() {
        // This firmware: bb b0 <link> b0 04 <charge> <pct>
        XCTAssertEqual(RapooProtocol.decodeNotification([0xBB, 0xB0, 0x42, 0xB0, 0x04, 0x01, 0x62]),
                       RapooProtocol.Notification(link: .receiver, percent: 98, charging: false))
        XCTAssertEqual(RapooProtocol.decodeNotification([0xBB, 0xB0, 0x41, 0xB0, 0x04, 0x02, 0x64]),
                       RapooProtocol.Notification(link: .cable, percent: 100, charging: true))
        // Without the report id.
        XCTAssertEqual(RapooProtocol.decodeNotification([0xB0, 0x42, 0xB0, 0x04, 0x01, 0x62]),
                       RapooProtocol.Notification(link: .receiver, percent: 98, charging: false))
        // gen1 shape: b0 51 20 03 <link> <pct>
        XCTAssertEqual(RapooProtocol.decodeNotification([0xB0, 0x51, 0x20, 0x03, 0x01, 0x62]),
                       RapooProtocol.Notification(link: .receiver, percent: 98, charging: nil))
        XCTAssertEqual(RapooProtocol.decodeNotification([0x51, 0x20, 0x03, 0x02, 0x64]),
                       RapooProtocol.Notification(link: .cable, percent: 100, charging: nil))
        XCTAssertNil(RapooProtocol.decodeNotification([0xB0, 0x42, 0xB0, 0x04, 0x01, 0xC8]))
    }

    func testLinkConnection() {
        XCTAssertEqual(RapooProtocol.linkConnection(0x01), "Receptor 2.4 GHz")
        XCTAssertEqual(RapooProtocol.linkConnection(0x41), "Cabo USB")
        XCTAssertEqual(RapooProtocol.linkConnection(0x42), "Receptor 2.4 GHz")
        XCTAssertNil(RapooProtocol.linkConnection(0xFF))
    }

    // MARK: Register blocks

    func testPerformanceBlock() {
        let block: [UInt8] = [0x82, 0x00, 0x82, 0xFF]
        let performance = RapooProtocol.decodePerformance(block)
        XCTAssertEqual(performance?.receiverCode, 0x82)
        XCTAssertEqual(performance?.wiredCode, 0x82)
        XCTAssertEqual(RapooProtocol.encodePerformance(performance!), block)
        XCTAssertEqual(RapooProtocol.pollingHz(forCode: 0x82), 4000)
        XCTAssertEqual(RapooProtocol.pollingHz(forCode: 0x84), 2000)
        XCTAssertEqual(RapooProtocol.pollingHz(forCode: 0x01), 1000)
        XCTAssertEqual(RapooProtocol.pollingHz(forCode: 0x02), 500)
        XCTAssertEqual(RapooProtocol.pollingHz(forCode: 0x04), 250)
        XCTAssertEqual(RapooProtocol.pollingHz(forCode: 0x08), 125)
        XCTAssertEqual(RapooProtocol.pollingCode(forHz: 4000), 0x82)
        XCTAssertEqual(RapooProtocol.pollingCode(forHz: 125), 0x08)
        XCTAssertNil(RapooProtocol.pollingHz(forCode: 0x00))
    }

    func testSensorBlock() {
        let block: [UInt8] = [0x01, 0x01, 0x01, 0x00]
        let sensor = RapooProtocol.decodeSensor(block)
        XCTAssertEqual(sensor?.liftOffCode, 1)
        XCTAssertEqual(sensor?.motionSync, true)
        // encodeSensor cannot recreate reserved bytes; the write path mutates
        // raw blocks in place instead. Check the known positions only.
        let encoded = RapooProtocol.encodeSensor(sensor!)
        XCTAssertEqual(encoded[0], 0x01)
        XCTAssertEqual(encoded[1], 0x01)
    }

    func testDpiTableBlock() {
        let block: [UInt8] = [0x90, 0x01, 0x20, 0x03, 0xB0, 0x04, 0x40, 0x06, 0x80, 0x0C,
                              0x00, 0x19, 0x90, 0x65, 0x02, 0x00]
        let table = RapooProtocol.decodeDpiTable(block)
        XCTAssertEqual(table?.stages, [400, 800, 1200, 1600, 3200, 6400, 26000])
        // The count byte stores stages-1: 0x02 → 3 enabled.
        XCTAssertEqual(table?.enabledStages, 3)
        XCTAssertEqual(table?.countByte, 2)
        XCTAssertEqual(RapooProtocol.encodeDpiTable(table!), block)
        XCTAssertNil(RapooProtocol.decodeDpiTable(
            [0x90, 0x01, 0x20, 0x03, 0xB0, 0x04, 0x40, 0x06, 0x80, 0x0C]))
    }

    func testActiveStageBlock() {
        let block: [UInt8] = [0x01, 0x00, 0x02, 0x01]
        XCTAssertEqual(RapooProtocol.decodeActiveStage(block), 1)
        XCTAssertEqual(RapooProtocol.encodeActiveStage(1), block)
    }

    func testTimingBlock() {
        let block: [UInt8] = [0x04, 0x04, 0x78, 0x03]
        let timing = RapooProtocol.decodeTiming(block)
        XCTAssertEqual(timing?.pressDebounceIndex, 4)   // 16 ms
        XCTAssertEqual(timing?.releaseDebounceIndex, 4)
        XCTAssertEqual(timing?.sleepMinutes, 120)
        XCTAssertEqual(timing?.angleSnapping, false)    // bit 0 set = off
        XCTAssertEqual(timing?.rippleControl, false)    // bit 1 set = off
        XCTAssertEqual(RapooProtocol.encodeTiming(timing!), block)
        XCTAssertEqual(timing!.pressDebounceIndex < RapooProtocol.debounceTimesMs.count,
                       true)
        XCTAssertEqual(RapooProtocol.debounceTimesMs, [1, 2, 4, 8, 16, 24, 32])
        XCTAssertEqual(RapooProtocol.debounceTimesMs[4], 16)
    }

    func testTimingFlagsOn() {
        let timing = RapooProtocol.decodeTiming([0x00, 0x00, 0x1E, 0x00])
        XCTAssertEqual(timing?.angleSnapping, true)
        XCTAssertEqual(timing?.rippleControl, true)
    }

    func testWriteAckFingerprint() {
        XCTAssertTrue(RapooProtocol.decodeWriteAck([0x01]))
        XCTAssertFalse(RapooProtocol.decodeWriteAck([0x02]))
        XCTAssertFalse(RapooProtocol.decodeWriteAck([0x01, 0x00])) // 2 bytes não é ACK
        XCTAssertTrue(RapooProtocol.decodeWriteAck([0xBA, 0x01]))  // com report id
        XCTAssertFalse(RapooProtocol.decodeWriteAck([]))
    }

    func testInferDpiScale() {
        XCTAssertEqual(RapooProtocol.inferDpiScale(
            stages: [400, 800, 1200, 1600, 3200, 6400, 26000]), 1)
        XCTAssertEqual(RapooProtocol.inferDpiScale(
            stages: [8, 16, 24, 32, 64, 128, 520]), 50)
        XCTAssertEqual(RapooProtocol.inferDpiScale(stages: [400, 800, 1000]), 50)
        XCTAssertEqual(RapooProtocol.inferDpiScale(stages: []), 50)
    }

    func testVariableLengthAnswerShape() throws {
        // Measured on the newer firmware: a 4-byte register read answers 8.
        let four = try RapooProtocol.decodeAnswer(
            [0x01, 0x00, 0x00, 0x00, 0x01, 0x82, 0x01, 0xFF], expectedLength: 4)
        XCTAssertEqual(four.block, [0x01, 0x82, 0x01, 0xFF])
        XCTAssertFalse(four.isBattery)
        // A 16-byte read answers with 20 bytes.
        let tail: [UInt8] = (0..<16).map { UInt8($0) }
        let sixteen = try RapooProtocol.decodeAnswer([0x01, 0x00, 0x00, 0x00] + tail,
                                                     expectedLength: 16)
        XCTAssertEqual(sixteen.block, tail)
    }

    func testCableFirmwareAnswerShape() throws {
        // Measured on the wired link of this firmware: `01 02 64 00 <payload>`
        // — byte 1 is a response type and byte 2 the battery percentage, so
        // the marker cannot tell block and battery apart: the length does.
        let answer = try RapooProtocol.decodeAnswer(
            [0x01, 0x02, 0x64, 0x00, 0x08, 0x00, 0x10, 0x00], expectedLength: 4)
        XCTAssertEqual(answer.block, [0x08, 0x00, 0x10, 0x00])
        XCTAssertFalse(answer.isBattery)
        XCTAssertEqual(answer.batteryPercent, 100)
        // The short answer (3 bytes) is the battery reading.
        let battery = try RapooProtocol.decodeAnswer([0x01, 0x02, 0x64], expectedLength: 4)
        XCTAssertTrue(battery.isBattery)
        XCTAssertEqual(battery.batteryPercent, 100)
    }

    func testLiveBatteryShape() {
        // Measured live: charging mouse at 100%.
        XCTAssertEqual(RapooProtocol.decodeBattery([0x01, 0x02, 0x64]),
                       RapooProtocol.Battery(percent: 100, charging: true))
    }

    func testBlockLengthsFollowRegisterMap() {
        XCTAssertEqual(RapooProtocol.Address.performance.blockLength, 4)
        XCTAssertEqual(RapooProtocol.Address.sensor.blockLength, 4)
        XCTAssertEqual(RapooProtocol.Address.dpiX.blockLength, 16)
        XCTAssertEqual(RapooProtocol.Address.dpiY.blockLength, 16)
        XCTAssertEqual(RapooProtocol.Address.activeStage.blockLength, 4)
        XCTAssertEqual(RapooProtocol.Address.timing.blockLength, 4)
        XCTAssertEqual(RapooProtocol.Address.sensorAngle.blockLength, 4)
    }
}
