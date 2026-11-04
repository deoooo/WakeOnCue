import Foundation
import SQLite3

/// A minimal wrapper over the system SQLite. Used from the main actor only.
nonisolated final class SQLiteDatabase {
  enum Value {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
  }

  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private var handle: OpaquePointer?

  /// `readOnly` opens an existing database without changing it, for the command-line tool
  /// reading next to the running app.
  init(url: URL, readOnly: Bool = false) throws {
    let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK
    else { throw Failure(message: "无法打开数据库：\(url.path)") }
    guard !readOnly else { return }
    try execute("PRAGMA journal_mode = WAL")
    try execute("PRAGMA foreign_keys = ON")
  }

  deinit { sqlite3_close(handle) }

  func execute(_ sql: String, _ bindings: [Value] = []) throws {
    let statement = try prepare(sql, bindings)
    defer { sqlite3_finalize(statement) }
    let status = sqlite3_step(statement)
    guard status == SQLITE_DONE || status == SQLITE_ROW else { throw error() }
  }

  /// Runs a query and maps every row.
  func query<T>(_ sql: String, _ bindings: [Value] = [], map: (Row) -> T?) throws -> [T] {
    let statement = try prepare(sql, bindings)
    defer { sqlite3_finalize(statement) }
    var rows: [T] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else { throw error() }
      if let value = map(Row(statement: statement)) { rows.append(value) }
    }
    return rows
  }

  var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

  func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN")
    do {
      try body()
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func prepare(_ sql: String, _ bindings: [Value]) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw error()
    }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in bindings.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .int(let v): sqlite3_bind_int64(statement, index, v)
      case .double(let v): sqlite3_bind_double(statement, index, v)
      case .text(let v): sqlite3_bind_text(statement, index, v, -1, transient)
      case .null: sqlite3_bind_null(statement, index)
      }
    }
    return statement
  }

  private func error() -> Failure {
    Failure(message: String(cString: sqlite3_errmsg(handle)))
  }

  struct Row {
    let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func text(_ column: Int32) -> String {
      guard let pointer = sqlite3_column_text(statement, column) else { return "" }
      return String(cString: pointer)
    }
    func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: double(column)) }
    func optionalDate(_ column: Int32) -> Date? { isNull(column) ? nil : date(column) }
  }
}

nonisolated extension SQLiteDatabase.Value {
  static func date(_ date: Date) -> Self { .double(date.timeIntervalSince1970) }
  static func optionalDate(_ date: Date?) -> Self { date.map { .double($0.timeIntervalSince1970) } ?? .null }
  static func json<T: Encodable>(_ value: T) -> Self {
    let data = (try? JSONEncoder().encode(value)) ?? Data()
    return .text(String(decoding: data, as: UTF8.self))
  }
}

nonisolated extension SQLiteDatabase.Row {
  func json<T: Decodable>(_ column: Int32, as type: T.Type) -> T? {
    try? JSONDecoder().decode(type, from: Data(text(column).utf8))
  }
}
