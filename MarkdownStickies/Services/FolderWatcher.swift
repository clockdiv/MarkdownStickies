import Foundation
import CoreServices

/// Watches scan roots for filesystem changes using FSEvents.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let callbackQueue = DispatchQueue(label: "MarkdownStickies.FolderWatcher")
    private var onChange: (@Sendable () -> Void)?

    func start(roots: [URL], onChange: @escaping @Sendable () -> Void) {
        stop()
        self.onChange = onChange

        guard !roots.isEmpty else { return }

        let paths = roots.map(\.path) as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange?()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer
            )
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        FSEventStreamStart(stream)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        onChange = nil
    }

    deinit {
        stop()
    }
}
