import Darwin
import Foundation

struct TranslationHardwareSnapshot: Equatable, Sendable {
    enum Pressure: String, Sendable { case normal, warning, critical, unknown }
    let physicalMemoryBytes: UInt64
    let pressure: Pressure

    static func current() -> Self {
        var level: Int32 = 0
        var length = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0)
        let pressure: Pressure
        if result != 0 { pressure = .unknown }
        else {
            switch level {
            case 1: pressure = .normal
            case 2: pressure = .warning
            case 4: pressure = .critical
            default: pressure = .unknown
            }
        }
        return .init(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, pressure: pressure)
    }
}

/// A device-specific estimate and current pressure signal, never a fit/quality qualification.
/// File sizes exclude activation peaks, KV caches and other applications' allocations.
struct TranslationResourceAssessment: Equatable, Sendable {
    let hardware: TranslationHardwareSnapshot
    let selectedWeightBytes: UInt64?
    var planningBudgetBytes: UInt64 { UInt64(Double(hardware.physicalMemoryBytes) * 0.8) }
    var exceedsPlanningBudget: Bool {
        selectedWeightBytes.map { $0 > planningBudgetBytes } ?? false
    }
    var canAttemptLoad: Bool { hardware.pressure != .critical }
    var hardwareLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: hardware.physicalMemoryBytes), countStyle: .memory)
            + " unified memory · pressure " + hardware.pressure.rawValue
    }
    var explanation: String {
        if hardware.pressure == .critical {
            return "macOS currently reports critical memory pressure. Translation is paused; release other model workloads or explicitly choose a lighter profile before retrying."
        }
        if exceedsPlanningBudget {
            return "The selected weight files exceed this Mac's planning budget before runtime allocations. Choose smaller components or precision explicitly. No model is replaced automatically."
        }
        if hardware.pressure == .warning {
            return "macOS currently reports elevated memory pressure. Resident models, activation peaks and other applications can exceed a weights-only estimate."
        }
        return "Model fit and latency depend on this Mac and current workloads. The planning budget reserves 20% of physical memory; it is an estimate, not a measured fit or qualification."
    }
}
