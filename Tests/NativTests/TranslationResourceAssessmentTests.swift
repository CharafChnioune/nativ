import XCTest

final class TranslationResourceAssessmentTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024
    func testPlanningBudgetScalesFrom16To128GBWithoutAUniversalModelBan() {
        let low = TranslationResourceAssessment(hardware: .init(physicalMemoryBytes: 16 * gib, pressure: .normal), selectedWeightBytes: 20 * gib)
        let high = TranslationResourceAssessment(hardware: .init(physicalMemoryBytes: 128 * gib, pressure: .normal), selectedWeightBytes: 20 * gib)
        XCTAssertTrue(low.exceedsPlanningBudget)
        XCTAssertFalse(high.exceedsPlanningBudget)
        XCTAssertEqual(Double(high.planningBudgetBytes), Double(low.planningBudgetBytes) * 8, accuracy: 8)
        XCTAssertTrue(low.canAttemptLoad, "A rough file-size estimate must not masquerade as observed critical pressure")
        XCTAssertTrue(high.canAttemptLoad)
    }
    func testSmallLocalProfileRemainsAvailableOn16GB() {
        let small = TranslationResourceAssessment(hardware: .init(physicalMemoryBytes: 16 * gib, pressure: .normal), selectedWeightBytes: 1_606_472_608)
        XCTAssertFalse(small.exceedsPlanningBudget)
        XCTAssertTrue(small.canAttemptLoad)
    }
    func testActualCriticalPressureStopsBothSmallAndLargeMemoryMachines() {
        for size in [16, 128] {
            let state = TranslationResourceAssessment(hardware: .init(physicalMemoryBytes: UInt64(size) * gib, pressure: .critical), selectedWeightBytes: 1)
            XCTAssertFalse(state.canAttemptLoad)
            XCTAssertTrue(state.explanation.contains("currently"))
        }
    }
    func testMissingMeasurementsAreNotReportedAsQualifiedFit() {
        let state = TranslationResourceAssessment(hardware: .init(physicalMemoryBytes: 128 * gib, pressure: .unknown), selectedWeightBytes: nil)
        XCTAssertFalse(state.exceedsPlanningBudget)
        XCTAssertTrue(state.explanation.contains("not a measured fit"))
    }
}
