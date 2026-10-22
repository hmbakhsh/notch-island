import AppKit

/// Verification codes from Gmail, as banners: Island asks Gmail (through the
/// Composio CLI, the same way other local tools reach it) every few seconds
/// for new mail that looks like a sign-in or verification code, pulls the
/// code out, and shows it. Clicking the banner (or Caps then ⏎) copies it.
/// On while "emailCodes" isn't false and the Composio CLI is installed.
final class EmailCodes {
    var onCode: ((Message) -> Void)?
    private var timer: Timer?
    private var busy = false
    private var seen = Set<String>()
    /// Only mail that arrives after Island starts; older codes are stale.
    private let started = Date()

    private static let cli = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".composio/composio").path
    private static let query = #"newer_than:1h (code OR verification OR verify OR OTP OR passcode OR "one-time" OR "sign in" OR "log in" OR login)"#

    static var available: Bool { FileManager.default.isExecutableFile(atPath: cli) }

    func setEnabled(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on, Self.available else { return }
        log("email codes: watching Gmail")
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let mails = Self.fetch()
            DispatchQueue.main.async {
                self.busy = false
                self.handle(mails)
            }
        }
    }

    private func handle(_ mails: [Mail]?) {
        guard let mails else { return }
        for mail in mails.reversed() where !seen.contains(mail.id) {
            seen.insert(mail.id)
            guard mail.date > started.addingTimeInterval(-30),
                  let code = Self.code(in: mail.subject + "\n" + mail.preview)
            else { continue }
            log("email code from \(mail.sender)")
            onCode?(Self.message(code: code, mail: mail))
        }
    }

    private static func message(code: String, mail: Mail) -> Message {
        var m = Message(title: code)
        let from = mail.sender.components(separatedBy: " <").first?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) ?? mail.sender
        m.body = from.isEmpty ? mail.subject : from
        m.icon = "key.fill"
        m.color = "yellow"
        m.source = "Copy"
        // "482 913" shows as sent but copies as "482913".
        let plain = code.filter { $0.isLetter || $0.isNumber }
        m.run = "printf %s '\(plain)' | /usr/bin/pbcopy"
        m.seconds = 30
        return m
    }

    // MARK: Gmail

    struct Mail {
        let id: String
        let date: Date
        let sender: String
        let subject: String
        let preview: String
    }

    private static func fetch() -> [Mail]? {
        let args: [String: Any] = [
            "query": query, "user_id": "me", "max_results": 10, "include_payload": false, "verbose": false,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: args) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["execute", "GMAIL_FETCH_EMAILS", "-d", String(decoding: json, as: UTF8.self)]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            log("email codes: can't run Composio: \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = (root["data"] as? [String: Any])?["messages"] as? [[String: Any]]
        else {
            log("email codes: Gmail fetch failed")
            return nil
        }
        let iso = ISO8601DateFormatter()
        return messages.compactMap { m in
            guard let id = m["messageId"] as? String,
                  let date = (m["messageTimestamp"] as? String).flatMap(iso.date(from:)),
                  (m["labelIds"] as? [String])?.contains("DRAFT") != true
            else { return nil }
            // The preview comes as a Python-style dict string: {'body': '…'}.
            var preview = "\(m["preview"] ?? "")"
            if let r = preview.range(of: "'body': ") { preview = String(preview[r.upperBound...]) }
            return Mail(
                id: id, date: date, sender: m["sender"] as? String ?? "",
                subject: m["subject"] as? String ?? "", preview: preview)
        }
    }

    // MARK: Finding the code

    /// A code is 4–8 characters, digits (maybe split "123 456" or "123-456")
    /// or capitals with at least one digit ("WKN97K"), near words like "code".
    /// Years and times aren't codes.
    static func code(in text: String) -> String? {
        let near = #"(?i:code|passcode|otp|pin|verification|verify|one-time|sign[- ]?in|log[- ]?in)(?:[^A-Za-z0-9]+[a-z]{1,12}){0,4}?[^A-Za-z0-9]+"#
        let token = #"\b((?=[A-Z0-9-]*\d)[A-Z0-9]{3,4}[- ]?[A-Z0-9]{3,4}|\d{4,8})\b"#
        let patterns = [
            near + token,                          // "code: 482913", "Login Code - WKN97K"
            #"\b(\d{4,8})\b(?=\s+is\s+your)"#,     // "482913 is your code"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let code = String(text[range])
                let digits = code.filter(\.isNumber)
                if code == digits, code.count == 4, let year = Int(code), (1990...2100).contains(year) { continue }
                return code
            }
        }
        return nil
    }
}
