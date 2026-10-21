// GPU sampler — IOPCIDevice models + IOAccelerator PerformanceStatistics utilization.
// Utilization path adapted from Stats GPU InfoReader (exelban/stats, MIT).

import Foundation
import IOKit

public final class GPUInfoSampler: Sampler<[GPUInfo]> {
    public override func read() {
        let pciModels = fetchPCIDisplayModels()
        let accelerators = fetchIOService("IOAccelerator") ?? []

        var gpus: [GPUInfo] = []
        var usedPCI = Set<Int>()

        for (index, accelerator) in accelerators.enumerated() {
            guard let stats = accelerator["PerformanceStatistics"] as? [String: Any] else { continue }
            let ioClass = (accelerator["IOClass"] as? String) ?? "GPU"
            let utilRaw = stats["Device Utilization %"] as? Int
                ?? stats["GPU Activity(%)"] as? Int
            var utilization: Double?
            if var v = utilRaw {
                if v > 100 { v = 100 }
                if v < 0 { v = 0 }
                utilization = Double(v) / 100.0
            }

            var model = (stats["model"] as? String) ?? ""
            var vendor: String?
            let accMatch = (
                (accelerator["IOPCIMatch"] as? String)
                    ?? (accelerator["IOPCIPrimaryMatch"] as? String)
                    ?? ""
            ).lowercased()

            for (i, pci) in pciModels.enumerated() where !usedPCI.contains(i) {
                if !pci.pciToken.isEmpty, accMatch.contains(pci.pciToken) {
                    model = pci.model
                    vendor = pci.vendor
                    usedPCI.insert(i)
                    break
                }
            }

            if model.isEmpty {
                if ioClass.lowercased().contains("agx") {
                    model = "Apple GPU"
                    vendor = "Apple"
                } else if ioClass.lowercased().contains("amd") {
                    model = "AMD Graphics"
                    vendor = "AMD"
                } else if ioClass.lowercased().contains("intel") {
                    model = "Intel Graphics"
                    vendor = "Intel"
                } else {
                    model = "GPU #\(index + 1)"
                }
            }
            #if arch(arm64)
            if vendor == nil { vendor = "Apple" }
            #endif

            gpus.append(GPUInfo(
                vendor: vendor,
                model: model,
                utilization: utilization,
                cores: nil
            ))
        }

        // Fallback: PCI display entries only (no util)
        if gpus.isEmpty {
            for pci in pciModels {
                gpus.append(GPUInfo(vendor: pci.vendor, model: pci.model, utilization: nil, cores: nil))
            }
        }

        publish(gpus)
    }

    private struct PCIDisplay {
        var model: String
        var vendor: String?
        var pciToken: String
    }

    private func fetchPCIDisplayModels() -> [PCIDisplay] {
        guard let list = fetchIOService("IOPCIDevice") else { return [] }
        let displays = list.filter { ($0["IOName"] as? String) == "display" }
        var out: [PCIDisplay] = []
        for dict in displays {
            guard let modelData = dict["model"] as? Data,
                  let modelName = String(data: modelData, encoding: .ascii)
            else { continue }
            let model = modelName.replacingOccurrences(of: "\0", with: "")
            var vendor: String?
            if let vendorID = dict["vendor-id"] as? Data {
                if vendorID.starts(with: [0x86, 0x80]) { vendor = "Intel" }
                else if vendorID.starts(with: [0x02, 0x10]) { vendor = "AMD" }
                else if vendorID.starts(with: [0x6B, 0x10]) || vendorID.starts(with: [0x02, 0x00]) {
                    vendor = "Apple"
                }
            }
            #if arch(arm64)
            if vendor == nil { vendor = "Apple" }
            #endif

            var pciToken = ""
            if let deviceID = dict["device-id"] as? Data, let vendorID = dict["vendor-id"] as? Data,
               deviceID.count >= 2, vendorID.count >= 2 {
                pciToken = String(
                    format: "%02hhx%02hhx%02hhx%02hhx",
                    deviceID[1], deviceID[0], vendorID[1], vendorID[0]
                ).lowercased()
            }
            out.append(PCIDisplay(model: model, vendor: vendor, pciToken: pciToken))
        }
        return out
    }

    private func fetchIOService(_ name: String) -> [NSDictionary]? {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator)
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var list: [NSDictionary] = []
        var obj = IOIteratorNext(iterator)
        while obj != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(obj, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props = properties?.takeRetainedValue() as NSDictionary? {
                list.append(props)
            }
            IOObjectRelease(obj)
            obj = IOIteratorNext(iterator)
        }
        return list.isEmpty ? nil : list
    }
}
