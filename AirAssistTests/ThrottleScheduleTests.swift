import XCTest
@testable import AirAssist

/// Covers `ThrottleSchedule.isActive(at:)` — the time-window gating
/// introduced for #60. Emphasis on the overnight-wrap path, since that's
/// the branch most likely to have a subtle bug (yesterday's selected
/// days vs today's).
final class ThrottleScheduleTests: XCTestCase {

    // Helper: construct a Date at a specific weekday/hour/minute in the
    // current calendar. `weekday` is 0-indexed Sunday = 0 to match
    // `ThrottleSchedule.days`.
    private func date(weekday: Int, hour: Int, minute: Int) -> Date {
        // Use Calendar.current (system timezone) so the weekday/hour readout
        // inside ThrottleSchedule.isActive — which also uses Calendar.current —
        // matches what the test constructed. Anchoring in a fixed timezone and
        // comparing against a different one caused hour-offset failures on CI.
        let cal = Calendar.current
        // 2024-01-07 was a Sunday in every timezone the tests care about.
        let anchor = cal.date(from: DateComponents(year: 2024, month: 1, day: 7,
                                                   hour: 12, minute: 0))!
        let day = cal.date(byAdding: .day, value: weekday, to: anchor)!
        var dc = cal.dateComponents([.year, .month, .day], from: day)
        dc.hour = hour; dc.minute = minute
        return cal.date(from: dc)!
    }

    // MARK: - Non-wrapping windows

    func testWeekdayWindowHit() {
        let s = ThrottleSchedule(days: ThrottleSchedule.weekdays(),
                                 startMinute: 9 * 60, endMinute: 17 * 60)
        XCTAssertTrue(s.isActive(at: date(weekday: 1, hour: 12, minute: 30)))  // Mon 12:30
    }

    func testWeekdayWindowMissByWeekday() {
        let s = ThrottleSchedule(days: ThrottleSchedule.weekdays(),
                                 startMinute: 9 * 60, endMinute: 17 * 60)
        XCTAssertFalse(s.isActive(at: date(weekday: 6, hour: 12, minute: 0))) // Saturday
    }

    func testWeekdayWindowBoundaryInclusiveStart() {
        let s = ThrottleSchedule(days: [1], startMinute: 9 * 60, endMinute: 17 * 60)
        XCTAssertTrue(s.isActive(at: date(weekday: 1, hour: 9, minute: 0)))
    }

    func testWeekdayWindowBoundaryExclusiveEnd() {
        let s = ThrottleSchedule(days: [1], startMinute: 9 * 60, endMinute: 17 * 60)
        XCTAssertFalse(s.isActive(at: date(weekday: 1, hour: 17, minute: 0)))
        XCTAssertTrue(s.isActive(at: date(weekday: 1, hour: 16, minute: 59)))
    }

    // MARK: - Wrapping (overnight) windows

    func testOvernightActiveBeforeMidnightOnSelectedDay() {
        // 22:00 → 06:00, Fridays selected.
        let s = ThrottleSchedule(days: [5], startMinute: 22 * 60, endMinute: 6 * 60)
        XCTAssertTrue(s.isActive(at: date(weekday: 5, hour: 23, minute: 30))) // Fri 23:30
    }

    func testOvernightActiveAfterMidnightNextDay() {
        // 22:00 Fri → 06:00 Sat: the Saturday early-morning slot should
        // also count even though Saturday isn't in `days`.
        let s = ThrottleSchedule(days: [5], startMinute: 22 * 60, endMinute: 6 * 60)
        XCTAssertTrue(s.isActive(at: date(weekday: 6, hour: 3, minute: 0)))  // Sat 03:00
    }

    func testOvernightInactiveOutsideWindow() {
        let s = ThrottleSchedule(days: [5], startMinute: 22 * 60, endMinute: 6 * 60)
        XCTAssertFalse(s.isActive(at: date(weekday: 5, hour: 12, minute: 0))) // Fri noon
        XCTAssertFalse(s.isActive(at: date(weekday: 6, hour: 9, minute: 0)))  // Sat morning
    }

    func testOvernightDoesNotLeakToOtherDays() {
        // Only Fridays. Thursday 23:00 must NOT be active — Thursday
        // isn't selected so its overnight doesn't apply.
        let s = ThrottleSchedule(days: [5], startMinute: 22 * 60, endMinute: 6 * 60)
        XCTAssertFalse(s.isActive(at: date(weekday: 4, hour: 23, minute: 0)))
    }
}
