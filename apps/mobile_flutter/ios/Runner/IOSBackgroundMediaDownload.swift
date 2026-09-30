import Foundation
import Flutter

enum IOSBackgroundMediaPolicy {
  static func origin(_ url: URL) -> String? {
    guard let scheme = url.scheme, let host = url.host else { return nil }
    let port = url.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)"
  }
  static func allows(url: URL, origin: String, kind: String, maxBytes: Int64,
                     authorization: String?, mediaType: String = "cipher") -> Bool {
    let pattern = kind == "matrix"
      ? "^/_matrix/(client/v1/media|media/v3)/download/[^/]+/.+$"
      : "^/api/v1/moments/media/content/[^/]+$"
    return url.scheme == "https" && url.user == nil && url.password == nil &&
      self.origin(url) == origin && url.path.range(of: pattern, options: .regularExpression) != nil &&
      (kind == "matrix" || kind == "moments") &&
      (kind == "matrix" ? mediaType == "cipher" : ["image", "video"].contains(mediaType)) &&
      (kind == "matrix" || authorization == nil) && maxBytes > 0 && maxBytes <= 67_108_864
  }
}

final class IOSBackgroundMediaAccountState {
  private let defaults: UserDefaults
  private(set) var account: String?
  private(set) var nonce: String?
  init(defaults: UserDefaults) {
    self.defaults = defaults
    account = defaults.string(forKey: "background-media.account")
    nonce = defaults.string(forKey: "background-media.nonce")
    if account?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == nil ||
       UUID(uuidString: nonce ?? "") == nil { clear() }
  }
  func activate(_ requested: String) -> String {
    if account == requested, let nonce = nonce { return nonce }
    clear(); account = requested; nonce = UUID().uuidString
    defaults.set(account, forKey: "background-media.account")
    defaults.set(nonce, forKey: "background-media.nonce")
    defaults.synchronize()
    return nonce!
  }
  func revoke(account: String, nonce: String) {
    if self.account == account && self.nonce == nonce { clear() }
  }
  func clear() {
    account = nil; nonce = nil
    defaults.removeObject(forKey: "background-media.account")
    defaults.removeObject(forKey: "background-media.nonce")
    defaults.synchronize()
  }
}

/// Background URLSession owns network requests; Dart only registers and later
/// consumes results. Persisted job metadata never contains URLs, headers or keys.
final class IOSBackgroundMediaDownload: NSObject, URLSessionDownloadDelegate {
  static let identifier = "com.liuhetong.mobile.background-media.v1"
  private struct Job: Codable {
    let account: String
    let nonce: String
    let id: String
    let origin: String
    let kind: String
    let mediaType: String
    let maxBytes: Int64
    let created: Date
    var state: String
  }
  private let queue = DispatchQueue(label: "chatflow.background-media")
  private let root: URL
  private let identity: IOSBackgroundMediaAccountState
  private var account: String? { identity.account }
  private var nonce: String? { identity.nonce }
  private var jobs: [String: Job] = [:]
  private var tasks: [String: URLSessionDownloadTask] = [:]
  private var restoring = true
  private var deferred: [() -> Void] = []
  private var completionHandler: (() -> Void)?
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    config.sessionSendsLaunchEvents = true
    config.isDiscretionary = false
    config.httpMaximumConnectionsPerHost = 2
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 24 * 60 * 60
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()
  override init() {
    let preferences = UserDefaults.standard
    root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("background-media-v1", isDirectory: true)
    identity = IOSBackgroundMediaAccountState(defaults: preferences)
    super.init()
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var excluded = root
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try? excluded.setResourceValues(values)
    if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
      for case let url as URL in files where url.pathExtension == "json" {
        if let data = try? Data(contentsOf: url), let job = try? JSONDecoder().decode(Job.self, from: data),
           validID(job.id), current(job), Date().timeIntervalSince(job.created) < 86400 {
          jobs[job.id] = job
        } else { try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("bin")); try? FileManager.default.removeItem(at: url) }
      }
    }
    session.getAllTasks { [weak self] restored in
      guard let self = self else { return }
      self.queue.async {
        for task in restored {
          if let description = task.taskDescription, let id = description.split(separator: "|").last.map(String.init),
             let job = self.jobs[id], description == "\(job.nonce)|\(id)", self.current(job),
             let download = task as? URLSessionDownloadTask {
            self.tasks[id] = download
          } else { task.cancel() }
        }
        for (id, var job) in self.jobs where job.state == "pending" && self.tasks[id] == nil {
          job.state = "failed"; self.jobs[id] = job; try? self.save(job)
        }
        self.restoring = false
        let waiting = self.deferred; self.deferred.removeAll()
        waiting.forEach { $0() }
      }
    }
  }
  private func validID(_ value: String) -> Bool {
    value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
  }
  private func current(_ job: Job) -> Bool { job.account == account && job.nonce == nonce }
  private func file(_ job: Job, _ ext: String) -> URL {
    root.appendingPathComponent(job.account).appendingPathComponent(job.nonce)
      .appendingPathComponent(job.id).appendingPathExtension(ext)
  }
  private func save(_ job: Job) throws {
    let url = file(job, "json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    try JSONEncoder().encode(job).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
  }
  private func clear() {
    // Revoke authority before cancel callbacks can arrive.
    identity.clear()
    tasks.values.forEach { $0.cancel() }; tasks.removeAll(); jobs.removeAll()
    if let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      files.forEach { try? FileManager.default.removeItem(at: $0) }
    }
  }
  private func fail(_ id: String) {
    guard var job = jobs[id], current(job) else { return }
    job.state = "failed"; jobs[id] = job; try? save(job)
    try? FileManager.default.removeItem(at: file(job, "bin"))
  }
  func attach(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "chatflow/background_media", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard let self = self else { result(nil); return }
        self.queue.async {
          let action = { self.handle(call, result: result) }
          if self.restoring { self.deferred.append(action) } else { action() }
        }
      }
  }
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    func finish(_ value: Any?) { DispatchQueue.main.async { result(value) } }
    do {
      guard let args = call.arguments as? [String: Any], let requestedAccount = args["account"] as? String,
            validID(requestedAccount) else { throw Rejected.invalid }
      if call.method == "activate" {
        if account != requestedAccount || nonce == nil {
          clear(); _ = identity.activate(requestedAccount)
        }
        finish(nonce); return
      }
      guard let requestedNonce = args["nonce"] as? String else { throw Rejected.invalid }
      if call.method == "revoke" {
        if account == requestedAccount && nonce == requestedNonce { clear() }
        finish(nil); return
      }
      guard account == requestedAccount && nonce == requestedNonce,
            let id = args["id"] as? String, validID(id) else { throw Rejected.invalid }
      switch call.method {
      case "enqueue":
        guard let raw = args["url"] as? String, let url = URL(string: raw),
              let origin = args["origin"] as? String, let kind = args["kind"] as? String,
              let mediaType = args["mediaType"] as? String,
              let max = args["maxBytes"] as? NSNumber,
              IOSBackgroundMediaPolicy.allows(url: url, origin: origin, kind: kind,
                maxBytes: max.int64Value, authorization: args["authorization"] as? String, mediaType: mediaType)
        else { throw Rejected.invalid }
        if let existing = jobs[id], existing.state != "failed" { finish(nil); return }
        guard jobs.values.filter({ $0.state == "pending" }).count < 192 else { throw Rejected.invalid }
        let job = Job(account: requestedAccount, nonce: requestedNonce, id: id, origin: origin,
          kind: kind, mediaType: mediaType, maxBytes: max.int64Value, created: Date(), state: "pending")
        try save(job); jobs[id] = job
        var request = URLRequest(url: url)
        if let authorization = args["authorization"] as? String { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let task = session.downloadTask(with: request)
        task.taskDescription = "\(requestedNonce)|\(id)"; tasks[id] = task; task.resume(); finish(nil)
      case "status":
        guard let job = jobs[id], current(job) else { finish(["state":"failed"]); return }
        if job.state == "complete" { finish(["state":"complete", "path":file(job, "bin").path]) }
        else { finish(["state":job.state]) }
      case "promote":
        tasks[id]?.priority = URLSessionTask.highPriority
        finish(nil)
      case "consume":
        if let job = jobs.removeValue(forKey: id) {
          tasks.removeValue(forKey: id)?.cancel()
          try? FileManager.default.removeItem(at: file(job, "bin"))
          try? FileManager.default.removeItem(at: file(job, "json"))
        }
        finish(nil)
      default: finish(FlutterMethodNotImplemented)
      }
    } catch { finish(FlutterError(code: "MEDIA_REJECTED", message: "Media request rejected", details: nil)) }
  }
  private enum Rejected: Error { case invalid }
  func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) -> Bool {
    guard identifier == Self.identifier else { return false }
    queue.async { self.completionHandler = completion; _ = self.session }
    return true
  }
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    queue.async {
      let completion = self.completionHandler; self.completionHandler = nil
      if let completion = completion { DispatchQueue.main.async(execute: completion) }
    }
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                  totalBytesExpectedToWrite: Int64) {
    queue.async {
      guard let id = downloadTask.taskDescription?.split(separator: "|").last.map(String.init), let job = self.jobs[id], self.current(job),
            self.tasks[id] === downloadTask,
            totalBytesWritten <= job.maxBytes, totalBytesExpectedToWrite <= job.maxBytes else {
        downloadTask.cancel(); return
      }
    }
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didFinishDownloadingTo location: URL) {
    // URLSession removes location after this delegate returns.
    queue.sync {
      guard let id = downloadTask.taskDescription?.split(separator: "|").last.map(String.init), var job = jobs[id], current(job),
            tasks[id] === downloadTask else { return }
      do {
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
              let finalURL = response.url, IOSBackgroundMediaPolicy.origin(finalURL) == job.origin,
              job.kind == "matrix" || (job.mediaType == "video"
                ? ["video/mp4", "video/quicktime"] : ["image/jpeg", "image/png", "image/webp", "image/gif"]).contains(response.mimeType ?? "")
        else { throw Rejected.invalid }
        let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 && size <= job.maxBytes else { throw Rejected.invalid }
        let total = jobs.values.filter { $0.state == "complete" }.reduce(Int64(0)) { sum, item in
          sum + (((try? FileManager.default.attributesOfItem(atPath: file(item,"bin").path)[.size]) as? NSNumber)?.int64Value ?? 0)
        }
        guard total + size <= 268_435_456 else { throw Rejected.invalid }
        let target = file(job, "bin")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: location, to: target)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        job.state = "complete"; jobs[id] = job; try save(job)
      } catch { fail(id) }
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    queue.async {
      guard let id = task.taskDescription?.split(separator: "|").last.map(String.init), self.tasks[id] === task else { return }
      self.tasks.removeValue(forKey: id)
      if error != nil { self.fail(id) }
    }
  }
}
