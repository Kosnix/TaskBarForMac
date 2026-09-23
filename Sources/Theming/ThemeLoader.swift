import Foundation

enum ThemeLoaderError: Error, CustomStringConvertible {
    case missingFile(String)
    case decodeFailed(String, Error)

    var description: String {
        switch self {
        case .missingFile(let name):
            return "Fichier de thème manquant: \(name)"
        case .decodeFailed(let name, let error):
            return "Impossible de lire \(name): \(error)"
        }
    }
}

/// Discovers theme folders (bundled + user-installed) and loads/validates their JSON.
enum ThemeLoader {

    /// User-installable themes live here, alongside the app's own support data.
    static var userThemesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("TaskbarReplacement/Themes", isDirectory: true)
    }

    /// Bundled themes: prefer the packaged .app's Contents/Resources/Themes, fall back to
    /// the SwiftPM resource bundle so `swift run` works during development.
    static var bundledThemesDirectory: URL? {
        if let mainResources = Bundle.main.resourceURL {
            let packaged = mainResources.appendingPathComponent("Themes", isDirectory: true)
            if FileManager.default.fileExists(atPath: packaged.path) {
                return packaged
            }
        }
        let devPath = Bundle.module.resourceURL?.appendingPathComponent("Resources/Themes", isDirectory: true)
        if let devPath, FileManager.default.fileExists(atPath: devPath.path) {
            return devPath
        }
        return nil
    }

    static func discoverThemeFolders() -> [URL] {
        let fm = FileManager.default
        var folders: [URL] = []

        for base in [bundledThemesDirectory, userThemesDirectory].compactMap({ $0 }) {
            guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for entry in entries {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                    folders.append(entry)
                }
            }
        }
        return folders
    }

    static func loadTheme(at folderURL: URL) throws -> Theme {
        let manifest: ThemeManifest = try decode("theme.json", in: folderURL)
        let tokens: ThemeTokens = try decode("tokens.json", in: folderURL)
        let layout: ThemeLayout = try decode("layout.json", in: folderURL)
        // categories.json is optional: a theme with no category icons still loads fine.
        let categoryIcons: [String: String] = (try? decode("categories.json", in: folderURL)) ?? [:]
        return Theme(manifest: manifest, tokens: tokens, layout: layout, categoryIcons: categoryIcons, folderURL: folderURL)
    }

    static func loadAllThemes() -> [Theme] {
        discoverThemeFolders().compactMap { folder in
            do {
                return try loadTheme(at: folder)
            } catch {
                print("[ThemeLoader] Thème ignoré (\(folder.lastPathComponent)): \(error)")
                return nil
            }
        }
    }

    private static func decode<T: Decodable>(_ filename: String, in folder: URL) throws -> T {
        let fileURL = folder.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL) else {
            throw ThemeLoaderError.missingFile(filename)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ThemeLoaderError.decodeFailed(filename, error)
        }
    }
}
