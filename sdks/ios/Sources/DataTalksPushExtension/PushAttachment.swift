import Foundation
import UserNotifications

/// A push's picture (`dt_image`) as a notification attachment: an https JPEG, PNG or GIF of at most 5 MB (as on Android), downloaded
/// within 10 seconds. It downloads to a file, not into memory, which the extension has little of. Otherwise the push shows without it.
enum PushAttachment {
    static let maxBytes = 5 * 1024 * 1024
    static let downloadTimeout: TimeInterval = 10

    /// The picture's URL if it's an https URL to download; otherwise nil.
    static func url(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// Calls `completion` with the attachment, or nil, on a background queue.
    static func download(_ url: URL, session: URLSession, fileManager: FileManager = .default, completion: @escaping (UNNotificationAttachment?) -> Void) {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: downloadTimeout)
        session.downloadTask(with: request) { location, response, _ in
            guard let location, let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
                completion(nil)
                return
            }

            completion(attachment(at: location, fileManager: fileManager))
        }.resume()
    }

    // The type comes from the file's first bytes: a server's Content-Type can be wrong, and the system needs the type up front.
    static func attachment(at location: URL, fileManager: FileManager = .default) -> UNNotificationAttachment? {
        // A resource value, not the file's attributes: those count as a file timestamp API, which needs a declared privacy reason.
        guard let size = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, accepts(size: size),
              let kind = ImageKind(header: firstBytes(of: location))
        else { return nil }

        // The downloaded file is deleted when the task ends: the attachment needs its own file, with the type's extension.
        let file = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(kind.fileExtension)")
        do {
            try fileManager.moveItem(at: location, to: file)
            return try UNNotificationAttachment(identifier: "dt_image", url: file, options: [UNNotificationAttachmentOptionsTypeHintKey: kind.typeIdentifier])
        } catch {
            try? fileManager.removeItem(at: file)
            return nil
        }
    }

    /// Whether a picture of this many bytes may be shown.
    static func accepts(size: Int) -> Bool {
        size > 0 && size <= maxBytes
    }

    private static func firstBytes(of file: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        return handle.readData(ofLength: 8)
    }

    private enum ImageKind {
        case jpeg, png, gif

        init?(header: Data) {
            let bytes = [UInt8](header)
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
                self = .jpeg
            } else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                self = .png
            } else if bytes.starts(with: Array("GIF8".utf8)) {
                self = .gif
            } else {
                return nil
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .gif: return "gif"
            }
        }

        var typeIdentifier: String {
            switch self {
            case .jpeg: return "public.jpeg"
            case .png: return "public.png"
            case .gif: return "com.compuserve.gif"
            }
        }
    }
}
