// Catalogue of Flydigi controllers: everything that differs between models lives here as data, so that
// adding a controller means adding a descriptor (+ fixtures/tests), not touching the protocol code.
// See docs/adding-a-controller.md. Only the Apex 4 family is *supported* today; the rest are seeded from
// Flydigi's own device-id table so that an unknown pad is at least identified.

import Foundation

public struct DeviceDescriptor: Sendable, Hashable, Identifiable {
    public enum Family: String, Sendable { case apex4, apex3, apex2, apex5, vader3, vader4pro, vader5, other }

    /// Which wire protocol generation the firmware speaks.
    public enum ProtocolVariant: String, Sendable {
        /// `A5 <cmd> … crc` over XInput (045e:028e) and `05 <cmd>` over DInput (04b4:2412). Apex 4 and older.
        case classic
        /// `5A A5 <cmd> <len> … crc` in 32-byte reports on the `0xFFA0` HID (report id per descriptor) with Flydigi's own VID `0x37D7` (Apex 5/6, Vader 5 Pro). Not implemented; docs/adding-a-controller.md §4.
        case newXInput
    }

    public enum Support: String, Sendable {
        case supported            // exercised on hardware
        case untested             // same protocol family; should work, nobody verified
        case unsupported          // different protocol; identified only
    }

    public struct Capabilities: Sendable, Hashable {
        public var ledGroups: Int
        public var screen: (width: Int, height: Int, maxFrames: Int)?
        public var configSlots: Int
        public var forceAdaptTriggers: Bool
        public var gyro: Bool
        public var grip: Bool                   // grip vibration motors
        public var triggerVibration: Bool
        public static func == (a: Capabilities, b: Capabilities) -> Bool { a.ledGroups == b.ledGroups && a.screen?.width == b.screen?.width && a.configSlots == b.configSlots }
        public func hash(into h: inout Hasher) { h.combine(ledGroups); h.combine(configSlots) }
    }

    public let id: UInt8                  // Flydigi `DeviceType` (what `A5 10` returns)
    public let code: String               // Flydigi device code used by their web API ("k2", "k5"…)
    public let name: String               // marketing name (marked "?" where inferred from the internal code)
    public let family: Family
    public let protocolVariant: ProtocolVariant
    public let support: Support
    public let capabilities: Capabilities

    public init(id: UInt8, code: String, name: String, family: Family, protocolVariant: ProtocolVariant, support: Support, capabilities: Capabilities) {
        self.id = id; self.code = code; self.name = name; self.family = family
        self.protocolVariant = protocolVariant; self.support = support; self.capabilities = capabilities
    }
}

public enum DeviceCatalog {
    static let apex4Capabilities = DeviceDescriptor.Capabilities(
        ledGroups: 4, screen: (160, 80, 35), configSlots: 4, forceAdaptTriggers: true, gyro: true, grip: true, triggerVibration: false)

    /// Apex 4 ("k2") family — verified on hardware (deviceId 84, fw 6.8.3.0).
    static let apex4Family: [DeviceDescriptor] = [
        (84, "k2", "Flydigi Apex 4"), (86, "k2", "Flydigi Apex 4 EVA"), (87, "k2", "Flydigi Apex 4 STN"),
        (92, "k2", "Flydigi Apex 4 Assassin's Creed"), (93, "k2", "Flydigi Apex 4 (RUS edition)"),
        (102, "k2", "Flydigi Apex 4 HSH"), (103, "k2", "Flydigi Apex 4 GS"), (104, "k2", "Flydigi Apex 4 SRS"),
    ].map { DeviceDescriptor(id: $0.0, code: $0.1, name: $0.2, family: .apex4, protocolVariant: .classic,
                             support: $0.0 == 84 ? .supported : .untested, capabilities: apex4Capabilities) }

    /// Other ids from Flydigi's `DeviceType` table (Space Station 4.2). Names with "?" are inferred from the internal code.
    static let others: [DeviceDescriptor] = {
        let classicNoScreen = DeviceDescriptor.Capabilities(ledGroups: 0, screen: nil, configSlots: 4, forceAdaptTriggers: false, gyro: true, grip: true, triggerVibration: false)
        let classic: [(UInt8, String, String, DeviceDescriptor.Family)] = [
            (16, "x9", "Flydigi X9", .other), (17, "x8", "Flydigi X8", .other), (18, "apex", "Flydigi Apex", .other), (19, "apex2", "Flydigi Apex 2", .apex2),
            (20, "f1", "Flydigi Vader (F1)?", .other), (21, "f1", "Flydigi Vader L (F1L)?", .other), (22, "f1p", "Flydigi Vader Pro (F1P)?", .other), (23, "f1", "Flydigi Vader (F1 v2)?", .other),
            (24, "k1", "Flydigi Apex 3", .apex3), (26, "k1", "Flydigi Apex 3 AeroSpace", .apex3), (29, "k1", "Flydigi Apex 3 One Piece", .apex3),
            (25, "fp1", "Flydigi Vader 2 Pro (FP1)?", .other), (30, "fp1", "Flydigi Vader 2 Pro Fate (FP1)?", .other), (31, "fp1", "Flydigi Vader 2 Pro S (FP1S)?", .other),
            (28, "f3", "Flydigi Vader 3", .vader3), (80, "f3p", "Flydigi Vader 3 Pro", .vader3), (81, "f3p", "Flydigi Vader 3 Pro One Piece", .vader3), (88, "f3p", "Flydigi Vader 3 Pro EVA", .vader3),
            (82, "fp2", "Flydigi Vader 2 Pro (FP2)?", .other), (83, "fp2", "Flydigi Vader 2 Pro Naruto (FP2)?", .other), (89, "fp2", "Flydigi Vader 2 Pro Wired (FP2)?", .other), (90, "fp2", "Flydigi Vader 2 Pro Switch (FP2)?", .other), (94, "fp2", "Flydigi Vader 2 Pro M (FP2M)?", .other),
            (85, "f4", "Flydigi Vader 4 (F4)?", .other), (91, "f4", "Flydigi Vader 4 Assassin's Creed (F4)?", .other),
            (95, "fp3", "Flydigi Direwolf 3", .other), (97, "fp3", "Flydigi Direwolf 3 Naruto (FP3)?", .other),   // 95 confirmed by a tester (fw 5.3.1.1)
            (32, "wee1", "Flydigi Wee 1", .other), (33, "wee2", "Flydigi Wee 2", .other), (34, "wee3", "Flydigi Wee 3", .other),
            (48, "q1", "Flydigi Q1", .other), (49, "d1", "Flydigi Direwolf (D1)?", .other), (50, "q1", "Flydigi Q1 (WCH)", .other),
            (64, "wasp", "Flydigi Wasp BT", .other), (65, "wasp", "Flydigi Wasp N", .other), (66, "wasp", "Flydigi Wasp X", .other), (67, "wasp2", "Flydigi Wasp 2", .other),
            (68, "g1", "Flydigi G1", .other), (69, "w2s", "Flydigi W2S", .other),
        ]
        let newer: [(UInt8, String, String, DeviceDescriptor.Family)] = [
            (128, "k5", "Flydigi Apex 5", .apex5), (129, "k5", "Flydigi Apex 5 EVA", .apex5), (133, "k5", "Flydigi Apex 5 MM", .apex5), (134, "k5", "Flydigi Apex 5 SRS", .apex5), (135, "k5", "Flydigi Apex 5 GS", .apex5), (136, "k5", "Flydigi Apex 5 LZ", .apex5),
            (132, "fp4", "Flydigi Vader 4 Pro", .vader4pro), (146, "fp4", "Flydigi Vader 4 Pro GS", .vader4pro), (147, "fp4", "Flydigi Vader 4 Pro JDB", .vader4pro), (148, "fp4", "Flydigi Vader 4 Pro MRFZ", .vader4pro),
            // 130 is the Vader 5 Pro: confirmed from its heartbeat reply (0x82) and USB product string, issue #1.
            (130, "f5", "Flydigi Vader 5 Pro", .vader5), (144, "f5", "Flydigi Vader 5 DBZ", .vader5), (145, "f5", "Flydigi Vader 5 HK3", .vader5),
            (149, "k6", "Flydigi Apex 6?", .other), (150, "k6", "Flydigi Apex 6 Pro?", .other),
        ]
        return classic.map { DeviceDescriptor(id: $0.0, code: $0.1, name: $0.2, family: $0.3, protocolVariant: .classic, support: .unsupported, capabilities: classicNoScreen) }
             + newer.map { DeviceDescriptor(id: $0.0, code: $0.1, name: $0.2, family: $0.3, protocolVariant: .newXInput, support: .unsupported, capabilities: classicNoScreen) }
    }()

    public static let all: [DeviceDescriptor] = apex4Family + others
    private static let byId: [UInt8: DeviceDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func descriptor(for deviceId: UInt8) -> DeviceDescriptor? { byId[deviceId] }
}

public extension DeviceInfo {
    var descriptor: DeviceDescriptor? { DeviceCatalog.descriptor(for: deviceId) }
    var modelName: String { descriptor?.name ?? "Flydigi controller (id \(deviceId))" }
}
