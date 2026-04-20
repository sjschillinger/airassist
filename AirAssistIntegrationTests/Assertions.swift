import Foundation

/// Tiny test assertion helpers for the CLI integration runner.
///
/// We don't link XCTest — it pulls in the Xcode test host machinery we
/// fought all day to avoid. These helpers throw `AssertionError` with a
/// source location + message; `main.swift` catches, logs, and continues
/// to the next test so one bad case doesn't abort the whole run.
struct AssertionError: Error, CustomStringConvertible {
    let message: String
    let file: StaticString
    let line: UInt
    var description: String { "\(file):\(line): \(message)" }
}

func assertTrue(_ cond: @autoclosure () -> Bool,
                _ message: @autoclosure () -> String = "",
                file: StaticString = #filePath,
                line: UInt = #line) throws {
    if !cond() {
        throw AssertionError(message: "assertTrue failed: \(message())", file: file, line: line)
    }
}

func assertNotNil<T>(_ value: T?,
                     _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath,
                     line: UInt = #line) throws {
    if value == nil {
        throw AssertionError(message: "assertNotNil failed: \(message())", file: file, line: line)
    }
}

func assertGreaterThan<T: Comparable>(_ a: T, _ b: T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath,
                                      line: UInt = #line) throws {
    if !(a > b) {
        throw AssertionError(message: "assertGreaterThan(\(a), \(b)): \(message())",
                             file: file, line: line)
    }
}
