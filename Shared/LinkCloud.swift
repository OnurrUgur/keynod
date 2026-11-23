import CloudKit
import Foundation
import Security

/// The private CloudKit zone both apps share. Only a handful of short-lived
/// records live there at a time; nothing needs a query index.
///
/// When built locally without CloudKit entitlements (e.g. ad-hoc Mac-only builds),
/// `isConfigured` is false and every operation fails cleanly instead of trapping.
final class LinkCloud {
    static let shared = LinkCloud()

    let containerID: String?
    let zoneID: CKRecordZone.ID
    private let _container: CKContainer?

    var isConfigured: Bool { _container != nil }

    var container: CKContainer? { _container }
    var database: CKDatabase? { _container?.privateCloudDatabase }

    init(containerID: String? = Link.containerID) {
        self.containerID = containerID
        zoneID = CKRecordZone.ID(zoneName: Link.zoneName, ownerName: CKCurrentUserDefaultName)
        if let containerID, Self.hasCloudKitEntitlement(for: containerID) {
            _container = CKContainer(identifier: containerID)
        } else {
            _container = nil
        }
    }

    /// On macOS, instantiating `CKContainer` without the matching entitlement aborts the process.
    /// Checking the code-signing entitlements first keeps unsigned/local Mac builds working cleanly.
    private static func hasCloudKitEntitlement(for containerID: String) -> Bool {
        #if os(macOS)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] else {
            return false
        }
        return containers.contains(containerID)
        #else
        return true
        #endif
    }

    private func requireDatabase() throws -> CKDatabase {
        guard let database else {
            throw LinkError.malformed("iCloud isn't configured for this build. Set KEYNOD_TEAM_ID and KEYNOD_ICLOUD_CONTAINER in Local.xcconfig.")
        }
        return database
    }

    func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }

    func newRecord(_ type: String, _ name: String) -> CKRecord {
        CKRecord(recordType: type, recordID: recordID(name))
    }

    /// True when CloudKit is configured and an iCloud account is signed in and usable.
    func isAvailable() async -> Bool {
        guard let container else { return false }
        return (try? await container.accountStatus()) == .available
    }

    func ensureZone() async throws {
        let db = try requireDatabase()
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
    }

    /// Saves a new record, creating the zone on first use. Throws
    /// `CKError.serverRecordChanged` when the name is already taken, so the
    /// first answer to a request can't be overwritten.
    func create(_ record: CKRecord) async throws {
        let db = try requireDatabase()
        do {
            _ = try await db.save(record)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            try await ensureZone()
            _ = try await db.save(record)
        }
    }

    /// Saves a record, replacing whatever is stored under its name (the mode record).
    func put(_ record: CKRecord) async throws {
        let db = try requireDatabase()
        func save() async throws {
            let results = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            if case .failure(let error) = results.saveResults[record.recordID] { throw error }
        }
        do {
            try await save()
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            try await ensureZone()
            try await save()
        }
    }

    /// The record, or nil when it doesn't exist (yet).
    func fetch(_ name: String) async throws -> CKRecord? {
        let db = try requireDatabase()
        do {
            return try await db.record(for: recordID(name))
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    /// Best effort; missing records are fine.
    func delete(_ names: [String]) async {
        guard !names.isEmpty, let db = database else { return }
        _ = try? await db.modifyRecords(saving: [], deleting: names.map(recordID))
    }

    /// Every record in the zone, read as zone changes (no index needed).
    func all() async throws -> [CKRecord] {
        let db = try requireDatabase()
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        while true {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion],
                          changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await db.recordZoneChanges(inZoneWith: zoneID, since: token)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                return []
            }
            for result in changes.modificationResultsByID.values {
                if case .success(let modification) = result { records.append(modification.record) }
            }
            token = changes.changeToken
            if !changes.moreComing { return records }
        }
    }
}

extension CKRecord {
    func data(_ key: String) -> Data? { self[key] as? Data }
    func string(_ key: String) -> String? { self[key] as? String }
    func date(_ key: String) -> Date? { self[key] as? Date }
}
