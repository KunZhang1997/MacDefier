// MinimalSMC — read-only temperature and fan RPM keys via AppleSMC.
// Layout/read path and temperature key catalogue adapted from Stats
// (exelban/stats, MIT) — Copyright (c) 2019 Serhiy Mytrovtsiy.
// No fan modes, target speeds, helper, or SMC write commands.

import Foundation
import IOKit

enum MinimalSMC {
    private static var connection: io_connect_t = 0
    private static let lock = NSLock()
    /// Whether the read-only AppleSMC user client can be opened. Apple Silicon
    /// also exposes this transport; individual keys still vary by hardware.
    static var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openIfNeeded()
    }

    // Names are technical English (language-neutral); groups match common product terms.
    private static let legacyTemperatureKeys: [(key: String, name: String, group: String)] = [
        ("TC0P", "CPU proximity", "CPU"),
        ("TC0D", "CPU die", "CPU"),
        ("TC0E", "CPU diode virtual", "CPU"),
        ("TC0F", "CPU diode filtered", "CPU"),
        ("Tg0P", "GPU proximity", "GPU"),
        ("TG0P", "GPU proximity", "GPU"),
        ("TGDD", "GPU die", "GPU"),
        ("TCGC", "GPU core", "GPU"),
        ("Th0H", "Heatsink", "System"),
        ("Ts0P", "Skin", "System"),
        ("TB0T", "Battery", "System")
    ]

    // A fixed, bounded catalogue from Stats values.swift, selected by chip family.
    // A key can change roles across generations. Never probe another generation's
    // table or claim a specific core number/type from the key spelling alone.
    static var temperatureKeys: [(key: String, name: String, group: String)] {
        #if arch(arm64)
        return temperatureKeys(forChip: Sysctl.string("machdep.cpu.brand_string"))
        #else
        return legacyTemperatureKeys
        #endif
    }

    static func temperatureKeys(forChip chip: String?) -> [(key: String, name: String, group: String)] {
        let tokens = Set((chip ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let cpuKeys: [String]
        let gpuKeys: [String]
        if tokens.contains("m1") {
            cpuKeys = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
            gpuKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        } else if tokens.contains("m2") {
            cpuKeys = ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
            gpuKeys = ["Tg0f", "Tg0j"]
        } else if tokens.contains("m3") {
            cpuKeys = ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
            gpuKeys = ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        } else if tokens.contains("m4") {
            cpuKeys = ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
            let firstGPUKeys = !tokens.isDisjoint(with: ["pro", "max", "ultra"]) ? ["Tg1U", "Tg1k"] : ["Tg0G", "Tg0H"]
            gpuKeys = firstGPUKeys + ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
        } else if tokens.contains("m5") {
            cpuKeys = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
            gpuKeys = ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
        } else {
            return legacyTemperatureKeys
        }
        var keys = legacyTemperatureKeys
        keys += cpuKeys.map { ($0, "CPU sensor \($0)", "CPU") }
        keys += gpuKeys.map { ($0, "GPU sensor \($0)", "GPU") }
        return keys
    }

    struct Sample {
        let readings: [SensorReading]
        let isAvailable: Bool
    }

    static func readTemperatures() -> [SensorReading] {
        sample().readings.filter { $0.unit == "°C" }
    }

    static func sample() -> Sample {
        lock.lock()
        defer { lock.unlock() }
        guard openIfNeeded() else { return Sample(readings: [], isAvailable: false) }
        return Sample(readings: readings(using: getValue), isAvailable: true)
    }

    /// Pure catalogue/filtering seam for deterministic tests, with no hardware IO.
    static func readings(using valueForKey: (String) -> Double?) -> [SensorReading] {
        var out: [SensorReading] = []
        var seen = Set<String>()
        for item in temperatureKeys {
            if seen.contains(item.key) { continue }
            guard let value = valueForKey(item.key), value.isFinite, (5...120).contains(value) else { continue }
            seen.insert(item.key)
            out.append(SensorReading(
                key: item.key,
                name: item.name,
                value: value,
                unit: "°C",
                group: item.group
            ))
        }
        // FNum and F{i}Ac are read-only. Zero RPM is a valid stopped fan;
        // missing fan data remains absent rather than being rendered as zero.
        if let count = valueForKey("FNum"), count.isFinite,
           count.rounded(.towardZero) == count, (0...8).contains(count) {
            for index in 0..<Int(count) {
                let key = "F\(index)Ac"
                guard let rpm = valueForKey(key), rpm.isFinite, (0...30_000).contains(rpm) else { continue }
                out.append(SensorReading(key: key, name: "Fan \(index + 1)", value: rpm, unit: "RPM", group: "Fans"))
            }
        }
        return out.sorted {
            if $0.group != $1.group { return $0.group < $1.group }
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
    }

    private static func openIfNeeded() -> Bool {
        if connection != 0 { return true }
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleSMC")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        let device = IOIteratorNext(iterator)
        guard device != 0 else { return false }
        defer { IOObjectRelease(device) }
        return IOServiceOpen(device, mach_task_self_, 0, &connection) == KERN_SUCCESS && connection != 0
    }

    // MARK: - SMC structs (match Stats)

    private struct Vers {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    private struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct KeyData {
        var key: UInt32 = 0
        var vers = Vers()
        var pLimitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let kernelIndex: UInt8 = 2
    private static let readKeyInfo: UInt8 = 9
    private static let readBytes: UInt8 = 5

    private static func fourCC(_ str: String) -> UInt32 {
        str.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func typeString(_ type: UInt32) -> String {
        let chars: [UInt8] = [
            UInt8((type >> 24) & 0xff),
            UInt8((type >> 16) & 0xff),
            UInt8((type >> 8) & 0xff),
            UInt8(type & 0xff)
        ]
        return String(bytes: chars, encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? ""
    }

    private static func getValue(_ key: String) -> Double? {
        var input = KeyData()
        var output = KeyData()
        input.key = fourCC(key)
        input.data8 = readKeyInfo
        var kr = call(kernelIndex, input: &input, output: &output)
        guard kr == KERN_SUCCESS, output.result == 0 else { return nil }

        let dataSize = output.keyInfo.dataSize
        let dataType = output.keyInfo.dataType
        guard dataSize > 0, dataSize <= 32 else { return nil }

        input.keyInfo.dataSize = dataSize
        input.data8 = readBytes
        kr = call(kernelIndex, input: &input, output: &output)
        guard kr == KERN_SUCCESS, output.result == 0 else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(dataSize))) }
        return decode(type: typeString(dataType), bytes: bytes)
    }

    static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "sp78", "sp87", "sp96":
            guard bytes.count == 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            let divisor = type == "sp78" ? 256.0 : (type == "sp87" ? 128.0 : 64.0)
            return Double(raw) / divisor
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "flt":
            guard bytes.count == 4 else { return nil }
            // Stats interprets flt in native order on supported little-endian Macs.
            // Assemble explicitly: no unaligned load and no blanket byte reversal.
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: raw))
            return value.isFinite ? value : nil
        case "ui8":
            return bytes.count == 1 ? Double(bytes[0]) : nil
        case "ui16":
            guard bytes.count == 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count == 4 else { return nil }
            return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default:
            return nil
        }
    }

    private static func call(_ index: UInt8, input: inout KeyData, output: inout KeyData) -> kern_return_t {
        let inputSize = MemoryLayout<KeyData>.stride
        var outputSize = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, UInt32(index), &input, inputSize, &output, &outputSize)
        guard result != KERN_SUCCESS || outputSize >= MemoryLayout<KeyData>.size else { return kIOReturnBadArgument }
        return result
    }
}
