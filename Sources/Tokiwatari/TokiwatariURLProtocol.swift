import Foundation

/// URLProtocol-based API logger: performs the actual transfer through an
/// internal URLSession (whose `protocolClasses` receives the
/// `underlyingURLProtocols` from `Tokiwatari.configure` — the mock hook) and
/// records an `event_kind = 'api'` row. Inert in Release (`canInit` is `false`).
public final class TokiwatariURLProtocol: URLProtocol, @unchecked Sendable {

    #if DEBUG
    /// Marker preventing re-entrant interception of the forwarded request.
    private static let handledRequestKey = "TokiwatariURLProtocol.handled"

    private var innerSession: URLSession?
    private var innerTask: URLSessionDataTask?
    #endif

    public override class func canInit(with request: URLRequest) -> Bool {
        #if DEBUG
        guard let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        guard URLProtocol.property(forKey: handledRequestKey, in: request) == nil else {
            return false
        }
        return Tokiwatari.isConfigured
        #else
        return false
        #endif
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        #if DEBUG
        let startDate = Date()
        let originalRequest = request

        guard let forwardedRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledRequestKey, in: forwardedRequest)

        // Inside a URLProtocol, `httpBody` is usually already converted to
        // `httpBodyStream`; read it to the end and hand the bytes back as a plain body.
        let requestBody: Data?
        if let body = originalRequest.httpBody {
            requestBody = body
        } else if let stream = originalRequest.httpBodyStream {
            let body = Self.readToEnd(stream)
            forwardedRequest.httpBodyStream = nil
            forwardedRequest.httpBody = body
            requestBody = body
        } else {
            requestBody = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        let underlying = Tokiwatari.underlyingURLProtocolsForInnerSession
        if !underlying.isEmpty {
            configuration.protocolClasses = underlying + (configuration.protocolClasses ?? [])
        }
        let session = URLSession(configuration: configuration)
        innerSession = session

        let task = session.dataTask(with: forwardedRequest as URLRequest) { [weak self] data, response, error in
            let endDate = Date()
            Tokiwatari.recordAPIEvent(
                request: originalRequest,
                requestBody: requestBody,
                response: response as? HTTPURLResponse,
                responseBody: data,
                error: error,
                start: startDate,
                end: endDate
            )
            defer { session.finishTasksAndInvalidate() }
            guard let self else { return }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        innerTask = task
        task.resume()
        #endif
    }

    public override func stopLoading() {
        #if DEBUG
        innerTask?.cancel()
        innerTask = nil
        #endif
    }

    #if DEBUG
    private static func readToEnd(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
    #endif
}
