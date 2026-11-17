import Foundation
import XCTest
@testable import DataTalksPush

/// The repository's `spec/` folder: the fixtures the SDK replays, and the schemas its bodies must fit.
enum Contract {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // DataTalksPushTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // sdks
        .deletingLastPathComponent()
        .appendingPathComponent("spec")

    static let appKey = "dtpk_stg_live_Fixture0AppKey000000000000000000"
    static let deviceSecret = "Fixture0Secret000000000000000000"
    static let wrongSecret = "Fixture0WrongSecret0000000000000"
    static let identityToken = "fixture.identity.token"
    static let installId = "3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
    static let apnsToken = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"

    static func fixtureNames() throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fixtures"), includingPropertiesForKeys: nil)
        return Set(files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    static func fixture(_ name: String) throws -> Fixture {
        let data = try Data(contentsOf: directory.appendingPathComponent("fixtures/\(name).json"))
        return Fixture(json: try JSONSerialization.jsonObject(with: data) as! [String: Any])
    }

    private static let schemas: [String: Any] = {
        let text = try! String(contentsOf: directory.appendingPathComponent("openapi/push-v1.yaml"), encoding: .utf8)
        let document = MiniYaml.parse(text)
        return (document["components"] as! [String: Any])["schemas"] as! [String: Any]
    }()

    /// Fails with what's wrong when `body` doesn't fit the named schema of the OpenAPI document.
    static func assertFits(_ schema: String, _ body: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        var problems: [String] = []
        checkObject(schemas[schema] as! [String: Any], body, path: schema, &problems)
        XCTAssertEqual(problems, [], "The body doesn't fit \(schema)", file: file, line: line)
    }

    private static func resolve(_ schema: [String: Any]) -> [String: Any] {
        guard let ref = schema["$ref"] as? String else { return schema }
        return schemas[String(ref.split(separator: "/").last!)] as! [String: Any]
    }

    private static func checkObject(_ raw: [String: Any], _ body: [String: Any], path: String, _ problems: inout [String]) {
        let schema = resolve(raw)
        let parts = [schema] + ((schema["allOf"] as? [[String: Any]])?.map(resolve) ?? [])

        var known = Set<String>()
        for part in parts {
            for name in part["required"] as? [String] ?? [] where body[name] == nil {
                problems.append("\(path).\(name) is required")
            }

            for (name, property) in part["properties"] as? [String: Any] ?? [:] {
                known.insert(name)
                if let value = body[name] {
                    checkValue(resolve(property as! [String: Any]), value, path: "\(path).\(name)", &problems)
                }
            }
        }

        if schema["additionalProperties"] as? Bool == false || schema["unevaluatedProperties"] as? Bool == false {
            for name in body.keys where !known.contains(name) {
                problems.append("\(path).\(name) isn't in the contract")
            }
        }
    }

    // The string formats the SDK's bodies use.
    private static let formats = [
        "uuid": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        "date-time": #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#,
    ]

    private static func checkValue(_ schema: [String: Any], _ value: Any, path: String, _ problems: inout [String]) {
        switch schema["type"] as? String {
        case "string":
            guard let text = value as? String else {
                problems.append("\(path) isn't a string")
                return
            }

            if let max = schema["maxLength"] as? Int, text.utf16.count > max { problems.append("\(path) is over \(max) characters") }
            if let min = schema["minLength"] as? Int, text.utf16.count < min { problems.append("\(path) is under \(min) characters") }
            if let pattern = schema["pattern"] as? String, text.range(of: pattern, options: .regularExpression) == nil { problems.append("\(path) doesn't match \(pattern)") }
            if let allowed = schema["enum"] as? [String], !allowed.contains(text) { problems.append("\(path) isn't one of \(allowed)") }
            if let format = schema["format"] as? String, let pattern = formats[format], text.range(of: pattern, options: .regularExpression) == nil {
                problems.append("\(path) isn't a \(format)")
            }
        case "boolean":
            if !(value is Bool) { problems.append("\(path) isn't a boolean") }
        case "object":
            guard let object = value as? [String: Any] else {
                problems.append("\(path) isn't an object")
                return
            }

            checkObject(schema, object, path: path, &problems)
        case "array":
            guard let items = value as? [Any] else {
                problems.append("\(path) isn't an array")
                return
            }

            if let min = schema["minItems"] as? Int, items.count < min { problems.append("\(path) has under \(min) items") }
            if let max = schema["maxItems"] as? Int, items.count > max { problems.append("\(path) has over \(max) items") }
            guard let itemSchema = schema["items"] as? [String: Any] else { return }
            for (index, item) in items.enumerated() {
                checkValue(resolve(itemSchema), item, path: "\(path)[\(index)]", &problems)
            }
        default:
            break
        }
    }
}

/// One scenario of `spec/fixtures`: see its README for the placeholders.
struct Fixture {
    private static let fieldsTheSdkDecides = ["install_id", "external_id", "email", "identity_token", "marketing_opt_in", "apns_token", "environment"]

    let json: [String: Any]

    private var steps: [[String: Any]] { json["steps"] as! [[String: Any]] }

    func request(_ step: Int) -> [String: Any] { steps[step]["request"] as! [String: Any] }

    func requestBody(_ step: Int) -> [String: Any] { request(step)["body"] as! [String: Any] }

    /// The step's response, with the sample values the fixtures README gives for SDK tests.
    func response(_ step: Int) -> StubResponse {
        let answer = steps[step]["response"] as! [String: Any]
        var headers = (answer["headers"] as? [String: String]) ?? [:]
        for (name, value) in headers where value == "{{any}}" {
            headers[name] = "1"
        }

        var body: Data?
        if let content = answer["body"] {
            let text = String(data: try! JSONSerialization.data(withJSONObject: content), encoding: .utf8)!
                .replacingOccurrences(of: "{{capture:device_secret}}", with: Contract.deviceSecret)
                .replacingOccurrences(of: "{{uuid}}", with: "00000000-0000-5000-8000-000000000000")
                .replacingOccurrences(of: "{{any}}", with: "fixture")
            body = Data(text.utf8)
        }

        return StubResponse(status: answer["status"] as! Int, headers: headers, body: body)
    }

    /// Checks what the SDK sent against the step: method, path and headers exactly, and the body against the schema. A registration's
    /// platform fields aren't compared unless the fixture is an iOS one: most fixtures register an Android device.
    func assertSent(_ step: Int, _ sent: RecordedRequest, schema: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let expected = request(step)
        XCTAssertEqual(sent.method, expected["method"] as? String, "method, step \(step)", file: file, line: line)
        XCTAssertEqual(sent.path, expected["path"] as? String, "path, step \(step)", file: file, line: line)
        XCTAssertEqual(sent.headers["X-DataTalks-App-Key"], Contract.appKey, "app key, step \(step)", file: file, line: line)
        XCTAssertEqual(sent.headers["X-DataTalks-SDK"], SdkInfo.header, "SDK header, step \(step)", file: file, line: line)

        let headers = expected["headers"] as? [String: String] ?? [:]
        var secret: String?
        switch headers["X-DataTalks-Device-Secret"] {
        case "{{device_secret}}": secret = Contract.deviceSecret
        case "{{wrong_device_secret}}": secret = Contract.wrongSecret
        default: secret = nil
        }
        XCTAssertEqual(sent.headers["X-DataTalks-Device-Secret"], secret, "device secret, step \(step)", file: file, line: line)

        guard let schema else { return }
        let body = sent.json
        Contract.assertFits(schema, body, file: file, line: line)

        let fixtureBody = requestBody(step)
        for name in Self.fieldsTheSdkDecides {
            guard let wanted = fixtureBody[name] else { continue }
            let text = "\(wanted)".replacingOccurrences(of: #"\{\{token:\w+\}\}"#, with: Contract.identityToken, options: .regularExpression)
            XCTAssertEqual(describe(body[name]), text, "\(name), step \(step)", file: file, line: line)
        }
    }

    private func describe(_ value: Any?) -> String? {
        value.map { "\($0)" }
    }
}

/// Just enough YAML for the OpenAPI document: maps, lists of maps, flow lists and scalars. Block scalars are skipped, because only descriptions use them.
enum MiniYaml {
    private struct Line {
        let indent: Int
        let text: String
    }

    static func parse(_ text: String) -> [String: Any] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw -> Line? in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            let trimmed = line.drop(while: { $0 == " " })
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return Line(indent: line.count - trimmed.count, text: String(trimmed))
        }

        var position = 0
        return parseMap(lines, &position, indent: 0)
    }

    private static func parseMap(_ lines: [Line], _ position: inout Int, indent: Int) -> [String: Any] {
        var map: [String: Any] = [:]
        while position < lines.count, lines[position].indent == indent, !lines[position].text.hasPrefix("- ") {
            let (key, value) = split(lines[position].text)
            position += 1
            guard let key else { continue }

            if value == "|" || value == ">" {
                while position < lines.count, lines[position].indent > indent { position += 1 }
            } else if value.isEmpty {
                map[key] = parseNested(lines, &position, parentIndent: indent)
            } else {
                map[key] = scalar(value)
            }
        }

        return map
    }

    private static func parseNested(_ lines: [Line], _ position: inout Int, parentIndent: Int) -> Any {
        guard position < lines.count, lines[position].indent > parentIndent else { return [String: Any]() }
        let indent = lines[position].indent
        guard lines[position].text.hasPrefix("- ") else { return parseMap(lines, &position, indent: indent) }

        var list: [Any] = []
        while position < lines.count, lines[position].indent == indent, lines[position].text.hasPrefix("- ") {
            let item = String(lines[position].text.dropFirst(2))
            let (key, value) = split(item)
            guard let key else {
                list.append(scalar(item))
                position += 1
                continue
            }

            var map: [String: Any] = [:]
            position += 1
            if value == "|" || value == ">" {
                while position < lines.count, lines[position].indent > indent + 2 { position += 1 }
            } else if value.isEmpty {
                map[key] = parseNested(lines, &position, parentIndent: indent + 2)
            } else {
                map[key] = scalar(value)
            }

            if position < lines.count, lines[position].indent == indent + 2 {
                map.merge(parseMap(lines, &position, indent: indent + 2)) { first, _ in first }
            }

            list.append(map)
        }

        return list
    }

    private static func split(_ text: String) -> (key: String?, value: String) {
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == ":" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " {
                    let key = String(text[..<index]).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    return (key, String(text[next...]).trimmingCharacters(in: .whitespaces))
                }
            }
            index = text.index(after: index)
        }

        return (nil, text)
    }

    private static func scalar(_ text: String) -> Any {
        if text.hasPrefix("["), text.hasSuffix("]") {
            return text.dropFirst().dropLast().split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
        }

        if text == "true" { return true }
        if text == "false" { return false }
        if let number = Int(text) { return number }
        return unquote(text)
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "'" || first == "\"" else { return text }
        return String(text.dropFirst().dropLast())
    }
}
