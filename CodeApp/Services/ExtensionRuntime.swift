//
//  ExtensionRuntime.swift
//  Code
//
//  Bridges VS Code extensions installed on device into the editor's extension host.
//
//  The editor web view is built on @codingame/monaco-vscode-api, which contains the
//  real VS Code extension host. That host cannot read the app sandbox, so this type
//  does two things every time the set of installed extensions changes:
//
//   1. Scans `Application Support/Extensions/<publisher>.<name>/`.
//   2. Writes `index.json` describing every package (manifest, file list, base URL).
//
//  The editor serves that directory over its local HTTP server (`/ext/...`) and the
//  bundle's `window.codeExtensions` reads the index at startup, registering each
//  package with the extension host by mapping its files to `http://127.0.0.1:<port>/ext/...`.
//

import Combine
import Foundation

@available(iOS 18.0, *)
final class ExtensionRuntime: ObservableObject {

    static let shared = ExtensionRuntime()

    /// Must match `EditorService.PORT` in MonacoImplementation.swift.
    static let port = 20234

    struct Package: Identifiable {
        let id: String  // publisher.name
        let directoryName: String
        let name: String
        let publisher: String
        let displayName: String?
        let version: String
        let description: String?
        let isWebExtension: Bool
        let entryPoint: String?
        let commands: [String]
        let path: URL
        var enabled: Bool

        var unsupportedReason: String? {
            isWebExtension
                ? nil
                : "Only web extensions (a \"browser\" entry point) can run inside the iOS editor."
        }
    }

    @Published private(set) var packages: [Package] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshed = Date.distantPast

    private static let disabledDefaultsKey = "ExtensionRuntime.disabledIDs"
    private static let maxIndexedFiles = 4000

    private init() {}

    // MARK: - Locations

    static var directory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Extensions", isDirectory: true)
    }

    static var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    static func baseURL(forDirectoryName name: String) -> String {
        let encoded =
            name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return "http://127.0.0.1:\(port)/ext/\(encoded)"
    }

    // MARK: - Enablement

    private var disabledIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.disabledDefaultsKey) ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.disabledDefaultsKey)
        }
    }

    func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }

    func setEnabled(_ id: String, enabled: Bool) {
        var disabled = disabledIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        disabledIDs = disabled
        reload()
    }

    // MARK: - Scanning

    /// Rescans the extensions directory, rewrites `index.json` and publishes the result.
    @discardableResult
    func reload() -> [Package] {
        let fm = FileManager.default
        var scanned: [Package] = []
        var error: String?

        do {
            try fm.createDirectory(
                at: Self.directory, withIntermediateDirectories: true, attributes: nil)

            let entries = (try? fm.contentsOfDirectory(
                at: Self.directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []

            let disabled = disabledIDs

            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { continue }

                let manifestURL = entry.appendingPathComponent("package.json")
                guard let data = try? Data(contentsOf: manifestURL),
                    let manifest = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                    let name = manifest["name"] as? String,
                    let version = manifest["version"] as? String
                else {
                    NSLog("ExtensionRuntime: skipping \(entry.lastPathComponent) (no manifest)")
                    continue
                }

                let publisher =
                    manifest["publisher"] as? String
                    ?? entry.lastPathComponent.split(separator: ".").first.map(String.init)
                    ?? "unknown"
                let id = "\(publisher).\(name)"
                let browser = manifest["browser"] as? String
                let main = manifest["main"] as? String

                let contributes = manifest["contributes"] as? [String: Any]
                let commands = (contributes?["commands"] as? [[String: Any]])?
                    .compactMap { $0["command"] as? String } ?? []

                scanned.append(
                    Package(
                        id: id,
                        directoryName: entry.lastPathComponent,
                        name: name,
                        publisher: publisher,
                        displayName: manifest["displayName"] as? String,
                        version: version,
                        description: manifest["description"] as? String,
                        isWebExtension: browser != nil,
                        entryPoint: browser ?? main,
                        commands: commands,
                        path: entry,
                        enabled: !disabled.contains(id)
                    ))
            }

            try writeIndex(packages: scanned)
        } catch {
            error = error.localizedDescription
            NSLog("ExtensionRuntime: reload failed: \(error)")
        }

        packages = scanned
        lastError = error
        lastRefreshed = Date()
        NSLog("ExtensionRuntime: \(scanned.count) extension(s) indexed")
        return scanned
    }

    // MARK: - Index generation

    /// Writes the JSON document consumed by `window.codeExtensions` in the editor bundle.
    func writeIndex(packages: [Package]) throws {
        var entries: [[String: Any]] = []

        for package in packages {
            guard let manifestData = try? Data(
                contentsOf: package.path.appendingPathComponent("package.json")),
                let manifest = try? JSONSerialization.jsonObject(with: manifestData)
            else { continue }

            entries.append([
                "id": package.id,
                "path": "/extensions/\(package.directoryName)",
                "baseUrl": Self.baseURL(forDirectoryName: package.directoryName),
                "files": Self.relativeFiles(in: package.path),
                "manifest": manifest,
                "enabled": package.enabled,
                "source": "vsix",
            ])
        }

        let document: [String: Any] = [
            "version": 1,
            "generated": ISO8601DateFormatter().string(from: Date()),
            "extensions": entries,
        ]

        let data = try JSONSerialization.data(
            withJSONObject: document, options: [.sortedKeys])
        try data.write(to: Self.indexURL, options: .atomic)
    }

    /// Every regular file under the package root, relative to it.
    private static func relativeFiles(in root: URL) -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        let rootPath = root.standardizedFileURL.path

        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return files }

        for case let url as URL in enumerator {
            if files.count >= maxIndexedFiles {
                NSLog("ExtensionRuntime: \(root.lastPathComponent) exceeds file limit, truncating")
                break
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            var path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") {
                path = String(path.dropFirst(rootPath.count + 1))
            }
            files.append(path)
        }
        return files.sorted()
    }

    // MARK: - Mutations

    /// Removes an installed extension from disk.
    func uninstall(_ id: String) throws {
        guard let package = packages.first(where: { $0.id == id }) else { return }
        try FileManager.default.removeItem(at: package.path)
        var disabled = disabledIDs
        disabled.remove(id)
        disabledIDs = disabled
        reload()
    }
}
