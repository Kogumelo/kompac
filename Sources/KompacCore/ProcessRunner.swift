import Foundation

/// Processes of an operation in progress; `cancel()` terminates them all.
final class ProcessGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []
    private var _cancelled = false

    var cancelled: Bool { lock.withLock { _cancelled } }

    /// Registers and starts the process; does not start it if the operation was already cancelled.
    func start(_ p: Process) throws -> Bool {
        try lock.withLock {
            if _cancelled { return false }
            try p.run()
            processes.append(p)
            return true
        }
    }

    func cancel() {
        let running: [Process] = lock.withLock {
            _cancelled = true
            return processes
        }
        for p in running where p.isRunning { p.terminate() }
    }

    /// Terminates the processes without marking as cancelled (the preview already read what it wanted).
    func stop() {
        let running = lock.withLock { processes }
        for p in running where p.isRunning { p.terminate() }
    }
}

/// Output of a run: exit code and stderr of each stage.
struct RunResult: Sendable {
    var statuses: [Int32]
    var stderr: [String]
    /// Reading stdout was stopped on purpose (`onStdout` returned `false`).
    var stoppedEarly = false

    var allStderr: String { stderr.joined(separator: "\n") }
}

enum ProcessRunner {
    /// 7zz's environment: an app opened from the Finder does not inherit `LANG`, and without a UTF-8
    /// locale 7zz replaces accented characters with "?" in the listing.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        return env
    }()

    /// Runs one or more stages piped together (stdout of one into stdin of the next).
    /// Blocks until done; `onStdout` receives the last stage's stdout in chunks and returns
    /// `false` to stop; `onStderr` receives each stage's stderr (with the stage index).
    static func run(executable: URL, stages: [[String]], group: ProcessGroup,
                    onStdout: (Data) -> Bool = { _ in true },
                    onStderr: @escaping @Sendable (Int, Data) -> Void = { _, _ in }) throws -> RunResult {
        precondition(!stages.isEmpty)
        var processes: [Process] = []
        var errPipes: [Pipe] = []
        var previousOut: Pipe?
        for args in stages {
            let p = Process()
            p.executableURL = executable
            p.arguments = args
            p.environment = environment
            // Closed stdin: if 7zz decides to ask for a password on the terminal, it gets end-of-file instead of hanging.
            if let prev = previousOut { p.standardInput = prev } else { p.standardInput = FileHandle.nullDevice }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            processes.append(p)
            errPipes.append(err)
            previousOut = out
        }
        let lastOut = previousOut!

        for p in processes {
            guard try group.start(p) else { throw ArchiveError.cancelled }
        }
        // The parent process does not use the write ends; closing them guarantees end-of-file on read.
        for (i, p) in processes.enumerated() {
            (p.standardOutput as? Pipe)?.fileHandleForWriting.closeFile()
            errPipes[i].fileHandleForWriting.closeFile()
        }

        // Each stage's stderr in parallel, so no pipe fills up and blocks the process.
        let errBox = ErrBox(count: processes.count)
        let readers = DispatchGroup()
        for (i, pipe) in errPipes.enumerated() {
            readers.enter()
            let handle = pipe.fileHandleForReading
            DispatchQueue.global().async {
                while true {
                    let d = handle.availableData
                    if d.isEmpty { break }
                    errBox.append(i, d)
                    onStderr(i, d)
                }
                readers.leave()
            }
        }

        var stoppedEarly = false
        let outHandle = lastOut.fileHandleForReading
        while true {
            let d = outHandle.availableData
            if d.isEmpty { break }
            if !onStdout(d) {
                stoppedEarly = true
                group.stop()
                break
            }
        }
        try? outHandle.close()
        for p in processes { p.waitUntilExit() }
        readers.wait()

        if group.cancelled { throw ArchiveError.cancelled }
        return RunResult(statuses: processes.map(\.terminationStatus),
                         stderr: errBox.strings, stoppedEarly: stoppedEarly)
    }

    /// Async version: runs on a global queue and terminates the processes if the `Task` is cancelled.
    static func runAsync(executable: URL, stages: [[String]],
                         onStdout: @escaping @Sendable (Data) -> Bool = { _ in true },
                         onStderr: @escaping @Sendable (Int, Data) -> Void = { _, _ in }) async throws -> RunResult {
        let group = ProcessGroup()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RunResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(with: Result {
                        try run(executable: executable, stages: stages, group: group,
                                onStdout: onStdout, onStderr: onStderr)
                    })
                }
            }
        } onCancel: {
            group.cancel()
        }
    }
}

private final class ErrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Data]
    init(count: Int) { data = Array(repeating: Data(), count: count) }
    func append(_ i: Int, _ d: Data) { lock.withLock { data[i].append(d) } }
    var strings: [String] { lock.withLock { data.map { String(decoding: $0, as: UTF8.self) } } }
}
