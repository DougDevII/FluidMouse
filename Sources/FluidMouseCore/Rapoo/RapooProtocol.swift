import Foundation

/// Codec of the Rapoo VT9 Pro configuration channel, transcribed from the
/// measured protocol in the vendor driver 1.6.29 study (openmouse
/// `rapoo-vt9-pro-testing.md`). Everything here is transport independent: the
/// HID layer only sends/receives frames, and all byte layout knowledge lives in
/// this file.
public enum RapooProtocol {
    // MARK: Identity

    public static let vendorID = 0x24AE
    /// The configuration collection (Usage Page `0xFF00`, Usage `0x000E`)
    /// identifies the channel; the product id varies between batches (wired
    /// `0x418A`, receiver `0x185A` were measured locally; `0x4405`/`0x1205` from
    /// the open captures) so it is never used for matching.
    public static let configUsagePage = 0xFF00
    public static let configUsage = 0x000E
    /// Output report 0xBA, 31 bytes of report data in both directions.
    public static let configReportID = 0xBA
    /// Unsolicited status notification (battery, link).
    public static let notifyReportID = 0xBB
    /// Vendor status block readable as a feature report while the mouse is idle.
    public static let statusReportID = 0x2A
    /// The one report that must never be touched: reading it disconnects the
    /// mouse until the cable is pulled. Present in the vendor driver, absent
    /// here on purpose.
    public static let forbiddenReportID = 0x2B

    /// Total report length including the report id on transports that keep it.
    /// The connection byte works with any value (0xFF, 0xA5, 0x00, 0x01 and
    /// 0x5A all answered), so the vendor convention is used.
    public static let frameLength = 31
    public static let connectionByte: UInt8 = 0xA5

    // MARK: Commands

    public enum Command: UInt8 {
        case read = 0xA4
        case write = 0xA5
        case battery = 0xAA
    }

    // MARK: Register map (profile 0 base 0x600 + vendor offsets)

    public enum Address: Int {
        case performance = 0x880   // 4: [0] 2.4 GHz rate code, [2] cable rate code
        case sensor = 0x884        // 4: [0] lift-off selector, [1] motion sync
        case dpiX = 0x888          // 16: seven LE u16 stages, [14] enabled count
        case activeStage = 0x898   // 4: [0] stage index
        case sensorAngle = 0x8C4   // 4: [0] angle in degrees
        case timing = 0x8C0        // 4: [0] press debounce idx, [1] release idx,
                                   //     [2] sleep minutes, [3] disable flags
        case dpiY = 0x8C8          // 16: same layout as dpiX

        public var blockLength: Int {
            switch self {
            case .performance, .sensor, .activeStage, .sensorAngle, .timing: return 4
            case .dpiX, .dpiY: return 16
            }
        }
    }

    // MARK: Frame encoding

    /// `request  [0] connection  [1] command  [2] payload length
    ///          [3..6] address u32 LE  [7..] data — zero padded to 31`
    public static func frame(_ command: Command, address: Int, data: [UInt8]) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: frameLength)
        frame[0] = connectionByte
        frame[1] = command.rawValue
        frame[2] = UInt8(data.count)
        frame[3] = UInt8(address & 0xFF)
        frame[4] = UInt8((address >> 8) & 0xFF)
        frame[5] = UInt8((address >> 16) & 0xFF)
        frame[6] = UInt8((address >> 24) & 0xFF)
        for (offset, byte) in data.enumerated() where offset + 7 < frameLength {
            frame[offset + 7] = byte
        }
        return frame
    }

    /// A read of `length` bytes at `address`.
    public static func frameRead(address: Int, length: Int) -> [UInt8] {
        frame(.read, address: address, data: [UInt8](repeating: 0, count: length))
    }

    /// A write of a complete block. The channel has no partial writes: the
    /// block must be the full register content (read-modify-write).
    public static func frameWrite(address: Int, block: [UInt8]) -> [UInt8] {
        precondition(block.count == blockLength(address), "Rapoo: bloco parcial não é permitido")
        return frame(.write, address: address, data: block)
    }

    static func blockLength(_ address: Int) -> Int {
        Address(rawValue: address)?.blockLength ?? 4
    }

    // MARK: Answer decoding

    /// `answer  [0] status (0x01 = OK for this command, non-zero = busy/old)
    ///          [1] 0 for a data block, non-zero for a battery answer
    ///          [2] battery percentage on a battery answer
    ///          [4..] the block`
    public struct Answer {
        public let ready: Bool
        public let isBattery: Bool
        public let batteryPercent: Int
        public let block: [UInt8]
    }

    public enum AnswerError: Error, Equatable {
        case frameTooShort
        case statusBusy
    }

    /// Decode one answer buffer. Windows strips the report id from
    /// `HidD_GetInputReport`; macOS IOKit omits it — but defensively accept a
    /// leading report id byte of either polarity.
    /// Decode one answer buffer. Windows strips the report id from
    /// `HidD_GetInputReport`; macOS IOKit answers variable-length reports.
    ///
    /// Two answer shapes exist in the field:
    /// - gen1: `01 00 00 00 <payload>` (byte 1 = marker: 0 block, != 0 battery);
    /// - this firmware: `01 02 64 00 <payload>` — byte 1 is a response type
    ///   (2) and byte 2 is the battery percentage, so the marker cannot be
    ///   used to tell the shapes apart. The **length** does: a battery answer
    ///   is 3 bytes, a block answer is 4 + payload.
    public static func decodeAnswer(_ buffer: [UInt8], expectedLength: Int) throws -> Answer {
        var data = buffer
        if data.count == frameLength + 1 && (data[0] == configReportID) {
            data.removeFirst()
        }
        guard data.count >= 3 else { throw AnswerError.frameTooShort }
        guard data[0] == 0x01 else { throw AnswerError.statusBusy }
        if data.count >= 4 + expectedLength {
            let block = Array(data[4..<(4 + expectedLength)])
            return Answer(ready: true, isBattery: false,
                          batteryPercent: Int(data[2]),
                          block: block)
        }
        // Short answer: the battery reading.
        return Answer(ready: true, isBattery: true, batteryPercent: Int(data[2]), block: [])
    }

    /// The write ACK is a bare `01` — a single byte, in contrast with a block
    /// answer (≥ 4 + length). This fingerprint lets the transport know a
    /// write landed without reading anything back.
    public static func decodeWriteAck(_ buffer: [UInt8]) -> Bool {
        var data = buffer
        if data.count > 1 && data.first == UInt8(configReportID) { data.removeFirst() }
        return data.count == 1 && data[0] == 0x01
    }

    /// The battery query does not follow the busy -> OK handshake: the marker
    /// lives in byte 1 already.
    public static func decodeBattery(_ buffer: [UInt8]) -> Battery? {
        var data = buffer
        if data.first == UInt8(configReportID) { data.removeFirst() }
        guard data.count >= 3 else { return nil }
        guard data[0] == 0x01, data[1] != 0 else { return nil }
        let percent = Int(data[2])
        guard (0...100).contains(percent) else { return nil }
        return Battery(percent: percent, charging: data[1] == 2)
    }

    /// Feature report 0x2A (`2a 01 00 00 04 21 50 00 00 62`): byte 9 is the
    /// percentage. Accept the id-kept and id-stripped shapes.
    public static func decodeFeatureStatus(_ buffer: [UInt8]) -> Int? {
        var data = buffer
        if data.first == UInt8(statusReportID) { data.removeFirst() }
        guard data.count >= 9 else { return nil }
        let percent = Int(data[8])
        return (0...100).contains(percent) ? percent : nil
    }

    /// Unsolicited `0xBB`, two measured shapes:
    /// - this firmware (7 bytes): `bb b0 <link> b0 04 <charge> <pct>` — link at
    ///   byte 2 (`0x41` = cabo, `0x42` = receptor 2.4 GHz), charge flag at byte
    ///   5 (`0x01` descarregando, `0x02` carregando), percentage at byte 6;
    /// - vendor driver gen1: `b0 51 20 03 <link> <pct>` (id preserved) or its
    ///   stripped twin `51 20 03 <link> <pct>` (`0x01` = receptor, `0x02` = cabo).
    public enum Link: Equatable {
        case receiver
        case cable
        case unknown
    }

    public struct Notification: Equatable {
        public let link: Link
        public let percent: Int
        public let charging: Bool?

        public init(link: Link, percent: Int, charging: Bool?) {
            self.link = link
            self.percent = percent
            self.charging = charging
        }
    }

    public static func decodeNotification(_ buffer: [UInt8]) -> Notification? {
        var data = buffer
        if data.count > 1 && data.first == UInt8(notifyReportID) { data.removeFirst() }
        if data.count == 6 {
            // Two shapes share the length: gen1 (`b0 51 20 03 <link> <pct>`) and
            // this firmware without the id (`b0 <link> b0 04 <charge> <pct>`).
            if data[1] == 0x51 {
                let percent = Int(data[5])
                guard (0...100).contains(percent) else { return nil }
                return Notification(link: link(from: data[4]), percent: percent, charging: nil)
            }
            let percent = Int(data[5])
            guard (0...100).contains(percent) else { return nil }
            return Notification(link: link(from: data[1]),
                               percent: percent,
                               charging: data[4] == 2 ? true : (data[4] == 1 ? false : nil))
        }
        if data.count == 5 {
            // gen1 stripped: 51 20 03 <link> <pct>
            let percent = Int(data[4])
            guard (0...100).contains(percent) else { return nil }
            return Notification(link: link(from: data[3]), percent: percent, charging: nil)
        }
        if data.count == 7 {
            // this firmware with the id kept: bb b0 <link> b0 04 <charge> <pct>
            let percent = Int(data[6])
            guard (0...100).contains(percent) else { return nil }
            return Notification(link: link(from: data[2]),
                               percent: percent,
                               charging: data[5] == 2 ? true : (data[5] == 1 ? false : nil))
        }
        return nil
    }

    /// Link byte → kind. Newer firmware: `0x41` cabo, `0x42` receptor.
    /// Gen1: `0x01` receptor, `0x02` cabo.
    public static func link(from code: UInt8) -> Link {
        switch code {
        case 0x41: return .cable
        case 0x42: return .receiver
        case 0x01: return .receiver
        case 0x02: return .cable
        default: return .unknown
        }
    }

    /// Link code → human connection. Measured: `0x04` = receptor 2.4 GHz
    /// (newer firmware), `0x01` = receptor (gen1 captures). Cable codes
    /// pending measurement — returned raw for the UI.
    public static func linkConnection(_ code: UInt8) -> String? {
        switch link(from: code) {
        case .receiver: return "Receptor 2.4 GHz"
        case .cable: return "Cabo USB"
        case .unknown: return nil
        }
    }

    // MARK: Value model

    public struct Battery: Equatable {
        public let percent: Int
        public let charging: Bool
    }

    public struct Performance: Equatable {
        public let receiverCode: UInt8
        public let wiredCode: UInt8
        public init(receiverCode: UInt8, wiredCode: UInt8) {
            self.receiverCode = receiverCode
            self.wiredCode = wiredCode
        }
    }

    public struct Sensor: Equatable {
        public let liftOffCode: Int
        public let motionSync: Bool
        public init(liftOffCode: Int, motionSync: Bool) {
            self.liftOffCode = liftOffCode
            self.motionSync = motionSync
        }
    }

    public struct DpiTable: Equatable {
        public let stages: [Int]      // exactly 7 little-endian u16 values
        public let enabledStages: Int // decoded: min(countByte + 1, 7)
        public let countByte: Int     // raw byte [14], stores stages-1

        public init(stages: [Int], enabledStages: Int, countByte: Int? = nil) {
            self.stages = stages
            self.enabledStages = enabledStages
            self.countByte = countByte ?? enabledStages - 1
        }
    }

    /// Two firmware layouts are known: values stored as raw DPI (vendor
    /// driver 1.6.29 on the gen1 captures: `90 01` = 400 … `90 65` = 26000)
    /// and as DPI divided by 50 (measured live on a newer firmware: `08 00` = 8
    /// → 400 … `08 02` = 520 → 26000). The scale is inferred from magnitude;
    /// writes always carry a confirm-by-read-back before the UI reports done.
    public static func inferDpiScale(stages: [Int]) -> Int {
        let maximum = stages.max() ?? 0
        return maximum > 2000 ? 1 : 50
    }

    public struct Timing: Equatable {
        public let pressDebounceIndex: Int
        public let releaseDebounceIndex: Int
        public let sleepMinutes: Int
        /// Bit 0 set = angle snap OFF, bit 1 set = ripple control OFF.
        public let angleSnapping: Bool
        public let rippleControl: Bool

        public init(pressDebounceIndex: Int, releaseDebounceIndex: Int,
                    sleepMinutes: Int, angleSnapping: Bool, rippleControl: Bool) {
            self.pressDebounceIndex = pressDebounceIndex
            self.releaseDebounceIndex = releaseDebounceIndex
            self.sleepMinutes = sleepMinutes
            self.angleSnapping = angleSnapping
            self.rippleControl = rippleControl
        }
    }

    /// Polling codes from the vendor driver's own switch table, confirmed
    /// against register 0x880.
    public static let pollingRates: [(code: UInt8, hz: Int)] = [
        (0x08, 125), (0x04, 250), (0x02, 500), (0x01, 1000),
        (0x84, 2000), (0x82, 4000), (0x81, 8000),
    ]

    public static func pollingHz(forCode code: UInt8) -> Int? {
        pollingRates.first { $0.code == code }?.hz
    }

    public static func pollingCode(forHz hz: Int) -> UInt8? {
        pollingRates.first { $0.hz == hz }?.code
    }

    /// Debounce presses: an index into this table, stored per press/release.
    public static let debounceTimesMs = [1, 2, 4, 8, 16, 24, 32]

    // MARK: Block decoding / encoding

    public static func decodePerformance(_ block: [UInt8]) -> Performance? {
        guard block.count >= 4 else { return nil }
        return Performance(receiverCode: block[0], wiredCode: block[2])
    }

    public static func encodePerformance(_ performance: Performance) -> [UInt8] {
        [performance.receiverCode, 0x00, performance.wiredCode, 0xFF]
    }
    // The trailing 0xFF matches every capture of 0x880 (reserve byte high).

    public static func decodeSensor(_ block: [UInt8]) -> Sensor? {
        guard block.count >= 4 else { return nil }
        return Sensor(liftOffCode: Int(block[0]), motionSync: block[1] != 0)
    }

    public static func encodeSensor(_ sensor: Sensor) -> [UInt8] {
        [UInt8(sensor.liftOffCode), sensor.motionSync ? 0x01 : 0x00, 0x00, 0x00]
    }

    public static func decodeDpiTable(_ block: [UInt8]) -> DpiTable? {
        guard block.count >= 16 else { return nil }
        var stages = [Int]()
        for slot in 0..<7 {
            let index = slot * 2
            let value = Int(block[index]) | Int(block[index + 1]) << 8
            stages.append(value)
        }
        // The count byte stores stages-1 (vendor doc): 2 → 3 enabled.
        let countByte = Int(block[14])
        return DpiTable(stages: stages, enabledStages: min(countByte + 1, 7), countByte: countByte)
    }

    public static func encodeDpiTable(_ table: DpiTable) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 16)
        for slot in 0..<7 {
            let value = table.stages[slot]
            block[slot * 2] = UInt8(value & 0xFF)
            block[slot * 2 + 1] = UInt8((value >> 8) & 0xFF)
        }
        block[14] = UInt8(max(1, min(6, table.enabledStages - 1)))
        return block
    }

    public static func decodeActiveStage(_ block: [UInt8]) -> Int? {
        guard block.count >= 1 else { return nil }
        return Int(block[0])
    }

    public static func encodeActiveStage(_ stage: Int) -> [UInt8] {
        [UInt8(stage), 0x00, 0x02, 0x01] // the other bytes arrived as 00 02 01
    }

    public static func decodeTiming(_ block: [UInt8]) -> Timing? {
        guard block.count >= 4 else { return nil }
        return Timing(
            pressDebounceIndex: Int(block[0]),
            releaseDebounceIndex: Int(block[1]),
            sleepMinutes: Int(block[2]),
            angleSnapping: block[3] & 0x01 == 0,
            rippleControl: block[3] & 0x02 == 0)
    }

    public static func encodeTiming(_ timing: Timing) -> [UInt8] {
        var flags: UInt8 = 0
        if !timing.angleSnapping { flags |= 0x01 }
        if !timing.rippleControl { flags |= 0x02 }
        return [UInt8(timing.pressDebounceIndex), UInt8(timing.releaseDebounceIndex),
                UInt8(timing.sleepMinutes), flags]
    }
}
