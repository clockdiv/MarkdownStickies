import Foundation

/// User-facing sync outcome (banner + persistent status + debug log).
public struct SyncFeedback: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case success
        case failure
        case warning
    }

    public var kind: Kind
    /// Short title for the overlay (e.g. "Synced").
    public var title: String
    /// One-line human message ("Received 2 · sent 1 to iPhone").
    public var message: String
    /// Longer status line that stays visible in the UI.
    public var statusLine: String
    /// Technical detail for errors (safe to show + paste into AI chats).
    public var detail: String?
    /// Stable machine-readable tag for debugging, e.g. `sync:ack-partial`.
    public var debugCode: String
    public var receivedCount: Int
    public var sentConfirmedCount: Int
    public var sentExpectedCount: Int
    public var peerName: String?

    public init(
        kind: Kind,
        title: String,
        message: String,
        statusLine: String,
        detail: String? = nil,
        debugCode: String,
        receivedCount: Int,
        sentConfirmedCount: Int,
        sentExpectedCount: Int,
        peerName: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.statusLine = statusLine
        self.detail = detail
        self.debugCode = debugCode
        self.receivedCount = receivedCount
        self.sentConfirmedCount = sentConfirmedCount
        self.sentExpectedCount = sentExpectedCount
        self.peerName = peerName
    }

    public static func from(
        result: SyncExchangeResult,
        role: SyncExchangeRole,
        peerName: String?,
        errorMessage: String? = nil
    ) -> SyncFeedback {
        if let errorMessage {
            return SyncFeedback(
                kind: .failure,
                title: "Sync failed",
                message: errorMessage,
                statusLine: "Sync failed — \(errorMessage)",
                detail: "role=\(role.rawValue) error=\(errorMessage)",
                debugCode: "sync:transport-error",
                receivedCount: 0,
                sentConfirmedCount: 0,
                sentExpectedCount: 0,
                peerName: peerName
            )
        }

        let peer = peerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let peerLabel = (peer?.isEmpty == false) ? peer! : "peer"
        let received = result.localAppliedIDs.count
        // Trust the peer's apply ACK for "sent" — not a prediction against their post-apply catalog.
        let sent = result.peerAppliedIDs.count
        let remaining = result.remainingOutboundIDs.count

        if !result.peerSupportsAck, sent > 0 || remaining > 0 || received > 0 {
            // Older peer: we may still have applied notes locally.
            if remaining > 0 {
                return SyncFeedback(
                    kind: .warning,
                    title: "Sync incomplete",
                    message: "Peer did not confirm apply (update the other app).",
                    statusLine: "Received \(received) · \(remaining) still needed on peer — no ACK",
                    detail: """
                    [\(SyncExchangeResult.debugHeader)] role=\(role.rawValue) peer=\(peerLabel) \
                    received=\(received) peerApplied=\(sent) remainingOut=\(remaining) \
                    peerSupportsAck=false protocol=\(SyncWireMessage.currentProtocolVersion)
                    """,
                    debugCode: "sync:no-ack",
                    receivedCount: received,
                    sentConfirmedCount: 0,
                    sentExpectedCount: remaining,
                    peerName: peer
                )
            }
        }

        if result.peerSupportsAck, remaining > 0 {
            return SyncFeedback(
                kind: .warning,
                title: "Sync incomplete",
                message: "Peer still needs \(remaining) note(s) from this device.",
                statusLine: "Received \(received) · sent \(sent) · \(remaining) still missing on peer",
                detail: """
                [\(SyncExchangeResult.debugHeader)] role=\(role.rawValue) peer=\(peerLabel) \
                received=\(received) sent=\(sent) remainingOut=\(remaining) \
                missingIDs=\(result.remainingOutboundIDs.map(\.uuidString).joined(separator: ",")) \
                peerAppliedIDs=\(result.peerAppliedIDs.map(\.uuidString).joined(separator: ","))
                """,
                debugCode: "sync:ack-partial",
                receivedCount: received,
                sentConfirmedCount: sent,
                sentExpectedCount: sent + remaining,
                peerName: peer
            )
        }

        // Success — including the common "already in sync" case (0/0).
        let imagesIn = result.imagesReceived
        let imagesOut = result.imagesSent
        let imageSuffix: String = {
            if imagesIn == 0, imagesOut == 0 { return "" }
            if imagesIn > 0, imagesOut > 0 {
                return " · images +\(imagesIn)/−\(imagesOut)"
            }
            if imagesIn > 0 { return " · \(imagesIn) image(s) in" }
            return " · \(imagesOut) image(s) out"
        }()

        let message: String
        if received == 0, sent == 0, imagesIn == 0, imagesOut == 0 {
            message = "Already in sync with \(peerLabel)"
        } else if received == 0, sent == 0 {
            message = "Notes up to date with \(peerLabel)" + imageSuffix
        } else if received > 0, sent > 0 {
            message = "Received \(received) · sent \(sent) to \(peerLabel)" + imageSuffix
        } else if received > 0 {
            message = "Received \(received) from \(peerLabel)" + imageSuffix
        } else {
            message = "Sent \(sent) to \(peerLabel)" + imageSuffix
        }

        let statusLine: String
        if received == 0, sent == 0, imagesIn == 0, imagesOut == 0 {
            statusLine = "Synced — already up to date with \(peerLabel)"
        } else {
            statusLine = "Synced — received \(received) · sent \(sent) to \(peerLabel)" + imageSuffix
        }

        return SyncFeedback(
            kind: .success,
            title: "Synced",
            message: message,
            statusLine: statusLine,
            detail: """
            [\(SyncExchangeResult.debugHeader)] role=\(role.rawValue) peer=\(peerLabel) \
            received=\(received) sent=\(sent) remoteCatalog=\(result.remoteNotes.count) \
            imagesIn=\(imagesIn) imagesOut=\(imagesOut) \
            peerSupportsAck=\(result.peerSupportsAck)
            """,
            debugCode: received == 0 && sent == 0 && imagesIn == 0 && imagesOut == 0
                ? "sync:noop"
                : "sync:ok",
            receivedCount: received,
            sentConfirmedCount: sent,
            sentExpectedCount: sent,
            peerName: peer
        )
    }
}

public enum SyncExchangeRole: String, Sendable {
    /// This device tapped Sync (client).
    case client
    /// This device received an inbound connection (server).
    case server
}

extension SyncExchangeResult {
    public static let debugHeader = "MSSync"

    /// Honest one-liner for the persistent status bar.
    public var statusSummary: String {
        SyncFeedback.from(result: self, role: .client, peerName: nil).statusLine
    }
}

/// Append-only sync timeline note (`debug-<device>.md`) — excluded from LAN sync catalogs.
public enum SyncDebugLog {
    public static func isDebugNote(url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.hasPrefix("debug-")
    }

    public static func fileURL(in directory: URL, deviceName: String) -> URL {
        let slug = NoteFilename.slugify(deviceName)
        return directory.appendingPathComponent("debug-\(slug).md", isDirectory: false)
    }

    public static func append(
        directory: URL,
        deviceName: String,
        lines: [String]
    ) {
        guard !lines.isEmpty else { return }
        let url = fileURL(in: directory, deviceName: deviceName)
        let stamp = isoStamp()
        let bodyLines = lines.map { "- `\(stamp)` \($0)" }.joined(separator: "\n")

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try String(contentsOf: url, encoding: .utf8)
                let next = existing.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                    + "\n"
                    + bodyLines
                    + "\n"
                try next.write(to: url, atomically: true, encoding: .utf8)
            } else {
                let header = """
                ---
                id: \(UUID().uuidString.lowercased())
                ---

                # Sync debug — \(deviceName)

                Local-only log (not synced). Compare timestamps with the peer's `debug-*.md`.

                """
                try (header + bodyLines + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            // Best-effort — never fail sync because of logging.
        }
    }

    public static func appendExchange(
        directory: URL,
        deviceName: String,
        role: SyncExchangeRole,
        feedback: SyncFeedback,
        result: SyncExchangeResult?
    ) {
        var lines: [String] = [
            "role=\(role.rawValue) code=\(feedback.debugCode) kind=\(feedback.kind.rawValue)",
            "msg=\(feedback.message)",
        ]
        if let peer = feedback.peerName, !peer.isEmpty {
            lines.append("peer=\(peer)")
        }
        if let result {
            lines.append(
                "received=\(result.localAppliedIDs.count) sent=\(result.peerAppliedIDs.count) "
                    + "remainingOut=\(result.remainingOutboundIDs.count) remoteCatalog=\(result.remoteNotes.count) "
                    + "imagesIn=\(result.imagesReceived) imagesOut=\(result.imagesSent) "
                    + "ack=\(result.peerSupportsAck)"
            )
            if !result.remainingOutboundIDs.isEmpty {
                lines.append(
                    "missingOut=\(result.remainingOutboundIDs.map(\.uuidString).joined(separator: ","))"
                )
            }
        }
        if let detail = feedback.detail {
            lines.append("detail=\(detail.replacingOccurrences(of: "\n", with: " "))")
        }
        append(directory: directory, deviceName: deviceName, lines: lines)
    }

    private static func isoStamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
