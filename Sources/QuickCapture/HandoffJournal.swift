import Foundation
import SQLite3

struct HandoffRecord: Identifiable {
    let manifest: HandoffManifest
    let state: String
    let attempts: Int
    let nextAttempt: Double
    let error: String?
    let receipt: HandoffReceipt?
    var id: String { manifest.request.payload.capture.capture_id }
}

/// Owned by the handoff actor; SQLite never stores the only copy of Markdown.
final class HandoffJournal {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw HandoffError.invalid("journal_open")
        }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON;")
        var version: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK else { throw HandoffError.invalid("journal_version") }
        defer { sqlite3_finalize(version) }
        guard sqlite3_step(version) == SQLITE_ROW, sqlite3_column_int(version, 0) <= 1 else { throw HandoffError.invalid("journal_version") }
        try execute("""
            CREATE TABLE IF NOT EXISTS handoffs (
                id TEXT PRIMARY KEY, manifest BLOB NOT NULL, state TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0,
                error TEXT, receipt BLOB);
            PRAGMA user_version=1;
            """)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HandoffError.invalid("journal_write") }
    }
    func register(_ manifest: HandoffManifest) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO handoffs(id,manifest,state) VALUES(?,?,'pending')", -1, &stmt, nil) == SQLITE_OK else { throw HandoffError.invalid("journal_prepare") }
        defer { sqlite3_finalize(stmt) }
        let bytes = try HandoffJSON.encode(manifest)
        sqlite3_bind_text(stmt, 1, manifest.request.payload.capture.capture_id, -1, transient)
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HandoffError.invalid("journal_register") }
    }
    func records() throws -> [HandoffRecord] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT manifest,state,attempts,next_attempt,error,receipt FROM handoffs ORDER BY rowid DESC", -1, &stmt, nil) == SQLITE_OK else { throw HandoffError.invalid("journal_read") }
        defer { sqlite3_finalize(stmt) }
        var result: [HandoffRecord] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw HandoffError.invalid("journal_read") }
            func data(_ i: Int32) -> Data { Data(bytes: sqlite3_column_blob(stmt, i)!, count: Int(sqlite3_column_bytes(stmt, i))) }
            let manifest = try JSONDecoder().decode(HandoffManifest.self, from: data(0))
            let state = String(cString: sqlite3_column_text(stmt, 1))
            let error = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let receipt = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : try JSONDecoder().decode(HandoffReceipt.self, from: data(5))
            result.append(HandoffRecord(manifest: manifest, state: state, attempts: Int(sqlite3_column_int(stmt, 2)), nextAttempt: sqlite3_column_double(stmt, 3), error: error, receipt: receipt))
        }
    }
    func update(_ id: String, state: String, attempts: Int, next: Double = 0, error: String? = nil, receipt: HandoffReceipt? = nil) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE handoffs SET state=?,attempts=?,next_attempt=?,error=?,receipt=? WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { throw HandoffError.invalid("journal_prepare") }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, state, -1, transient)
        sqlite3_bind_int(stmt, 2, Int32(attempts))
        sqlite3_bind_double(stmt, 3, next)
        if let error { sqlite3_bind_text(stmt, 4, error, -1, transient) }
        if let receipt {
            let bytes = try HandoffJSON.encode(receipt)
            _ = bytes.withUnsafeBytes { sqlite3_bind_blob(stmt, 5, $0.baseAddress, Int32($0.count), transient) }
        }
        sqlite3_bind_text(stmt, 6, id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HandoffError.invalid("journal_update") }
    }
}
