// Adapted from Stats Kit helpers (MIT) — Copyright (c) 2019 Serhiy Mytrovtsiy.

import Foundation
import Darwin

public enum Sysctl {
    public static func byName(_ name: String) -> Int64 {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var value = Int64(0)
        guard size <= MemoryLayout<Int64>.size else { return 0 }
        sysctlbyname(name, &value, &size, nil, 0)
        return value
    }

    public static func string(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        let result = sysctlbyname(name, &buffer, &size, nil, 0)
        guard result == 0 else { return nil }
        return String(cString: buffer)
    }
}
