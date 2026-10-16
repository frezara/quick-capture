import Foundation

/// Calls `onChange` on the main queue when a file is written or replaced.
/// Atomic writes (temp + rename) orphan the watched descriptor, so a `.rename`
/// or `.delete` re-opens the path after a beat and then reports the change.
/// A path that doesn't exist yet is simply not watched.
final class FileWatcher {
    let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var reopen: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit { cancel() }

    func cancel() {
        reopen?.cancel()
        reopen = nil
        source?.cancel()
        source = nil
    }

    private func start() {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.handle() }
        // Capture this watcher's descriptor; a delayed cancellation must not
        // close the replacement watcher's descriptor.
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.source = source
    }

    private func handle() {
        guard let source else { return }
        let event = source.data
        guard event.contains(.rename) || event.contains(.delete) else { onChange(); return }
        source.cancel()
        self.source = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.start()
            self.onChange()
        }
        reopen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
}
