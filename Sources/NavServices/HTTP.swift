import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 最小 HTTP 抽象：测试注入假实现，App 里用 URLSession。
public protocol HTTPClient: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, status: Int)
}

public struct HTTPStatusError: Error, Equatable {
    public var status: Int
}

public struct TimeoutError: Error, Equatable {}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let box = TaskBox()
        // 取消要真的取消网络请求：否则"超时就不等它"会因为 task group 等子任务结束而失效。
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(data: Data, status: Int), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
                    }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func set(_ t: URLSessionDataTask) {
        lock.lock()
        task = t
        let c = cancelled
        lock.unlock()
        if c { t.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

/// 给异步操作加硬超时。操作必须响应取消（Task.sleep、URLSessionHTTPClient 都会）。
public func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                     _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
