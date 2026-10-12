import AppKit
import OpenDirectory

/// The current macOS user's actual account picture (System Settings →
/// Users & Groups), for the start menu's account header — there's no
/// simple public API for this; `OpenDirectory`'s `kODAttributeTypeJPEGPhoto`
/// on the local user record is the standard, long-used technique (the same
/// one login-window-replacement utilities rely on).
enum AccountPhoto {
    static func current() -> NSImage? {
        let session = ODSession.default()
        guard
            let node = try? ODNode(session: session, type: ODNodeType(kODNodeTypeLocalNodes)),
            let query = try? ODQuery(
                node: node,
                forRecordTypes: kODRecordTypeUsers,
                attribute: kODAttributeTypeRecordName,
                matchType: ODMatchType(kODMatchEqualTo),
                queryValues: NSUserName(),
                returnAttributes: kODAttributeTypeJPEGPhoto,
                maximumResults: 1
            ),
            let results = try? query.resultsAllowingPartial(false) as? [ODRecord],
            let record = results.first,
            let values = try? record.values(forAttribute: kODAttributeTypeJPEGPhoto) as? [Data],
            let data = values.first
        else {
            return nil
        }
        return NSImage(data: data)
    }
}
