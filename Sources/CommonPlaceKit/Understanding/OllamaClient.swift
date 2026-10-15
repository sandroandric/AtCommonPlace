import Foundation

/// The local Ollama server: version, models, pulls, generation with images,
/// and embeddings (text, or an image with text, as EmbeddingGemma 2 takes).
public struct OllamaClient: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Nothing answered (Ollama is not running).
        case unreachable(String)
        /// Ollama answered with an error (a missing model, a bad request).
        case server(status: Int, message: String)
        case badReply(String)

        public var description: String {
            switch self {
            case .unreachable(let why): return "Ollama is not reachable (\(why))"
            case .server(let status, let message): return "Ollama answered \(status): \(message)"
            case .badReply(let why): return "Unexpected reply from Ollama: \(why)"
            }
        }
    }

    public var host: URL
    let session: URLSession

    public init(host: URL = URL(string: "http://127.0.0.1:11434")!, session: URLSession = .shared) {
        self.host = host
        self.session = session
    }

    public func version() async throws -> String {
        let reply = try await request("GET", "/api/version", body: nil, timeout: 3)
        guard let version = reply["version"] as? String else { throw Failure.badReply("no version") }
        return version
    }

    /// Names of the pulled models.
    public func models() async throws -> [String] {
        let reply = try await request("GET", "/api/tags", body: nil, timeout: 5)
        return (reply["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// Whether `model` is pulled (a bare name means its `:latest` tag).
    public static func has(_ model: String, in names: [String]) -> Bool {
        let wanted = model.contains(":") ? model : "\(model):latest"
        return names.contains(wanted) || names.contains(model)
    }

    /// One answer for `prompt` (with `images`, PNG/JPEG data), as JSON when
    /// `json` is true.  Thinking is off: the answer is wanted, not the trace.
    public func generate(
        model: String, prompt: String, system: String? = nil, images: [Data] = [],
        json: Bool = true, maxTokens: Int = 700, timeout: TimeInterval = 180
    ) async throws -> String {
        var body: [String: Any] = [
            "model": model, "prompt": prompt, "stream": false, "think": false,
            "keep_alive": "10m",
            "options": ["temperature": 0.2, "num_predict": maxTokens, "num_ctx": 8192],
        ]
        if let system { body["system"] = system }
        if !images.isEmpty { body["images"] = images.map { $0.base64EncodedString() } }
        if json { body["format"] = "json" }
        let reply = try await request("POST", "/api/generate", body: body, timeout: timeout)
        guard let text = reply["response"] as? String else { throw Failure.badReply("no response text") }
        return text
    }

    /// One input of an embedding call: text, an image, or both.
    public struct EmbedInput: Sendable {
        public var text: String?
        public var image: Data?
        public init(text: String? = nil, image: Data? = nil) {
            self.text = text
            self.image = image
        }
    }

    /// One unit-length vector per input, in order.
    public func embed(model: String, inputs: [EmbedInput], timeout: TimeInterval = 60) async throws -> [[Float]] {
        let items: [Any] = inputs.map { input in
            if input.image == nil, let text = input.text { return text }
            var item: [String: String] = [:]
            if let text = input.text { item["text"] = text }
            if let image = input.image { item["image"] = image.base64EncodedString() }
            return item
        }
        let reply = try await request("POST", "/api/embed",
                                      body: ["model": model, "input": items, "keep_alive": "10m"], timeout: timeout)
        guard let raw = reply["embeddings"] as? [[Double]], raw.count == inputs.count else {
            throw Failure.badReply("expected \(inputs.count) embeddings")
        }
        return raw.map { VectorMath.unit($0.map(Float.init)) }
    }

    /// Pull `model`, reporting (completed, total) bytes as they come.
    public func pull(model: String, progress: @escaping @Sendable (Int64, Int64, String) -> Void) async throws {
        var request = URLRequest(url: host.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.server(status: http.statusCode, message: "pull \(model)")
        }
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = event["error"] as? String { throw Failure.server(status: 200, message: error) }
            let status = event["status"] as? String ?? ""
            let completed = (event["completed"] as? NSNumber)?.int64Value ?? 0
            let total = (event["total"] as? NSNumber)?.int64Value ?? 0
            progress(completed, total, status)
        }
    }

    // MARK: - Transport

    private func request(_ method: String, _ path: String, body: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: host.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Failure.unreachable(error.localizedDescription)
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.server(status: http.statusCode,
                                 message: object?["error"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let object else { throw Failure.badReply("not a JSON object") }
        return object
    }
}

/// Small vector helpers: unit length, cosine (dot product of unit vectors), centroids.
public enum VectorMath {
    public static func unit(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }

    /// The unit mean of `vectors` (all the same length).
    public static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count {
            for i in v.indices { sum[i] += v[i] }
        }
        return unit(sum)
    }
}
