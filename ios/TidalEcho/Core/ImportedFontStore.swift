import CoreText
import Foundation
import UIKit

struct ImportedChatFont: Identifiable, Sendable {
    let postScriptName: String
    let displayName: String

    var id: String { postScriptName }
    var chatFont: EchoChatFont { .imported(postScriptName) }
}

/// App-local font files are registered again each launch; no system installation.
enum ImportedFontStore {
    static let supportedExtensions: Set<String> = ["ttf", "otf", "ttc"]
    private static let maximumFileSize = 128 * 1024 * 1024

    enum ImportError: LocalizedError {
        case unsupportedFile, oversizedFile, invalidFont, conflictingFont, registrationFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFile: return "请选择 TTF、OTF 或 TTC 字体文件。"
            case .oversizedFile: return "字体文件太大，请选择小于 128 MB 的文件。"
            case .invalidFont: return "没有读到有效字体，请检查文件是否完整。"
            case .conflictingFont: return "有同名字体已经可用，请选择已导入的字体或换一个字体文件。"
            case .registrationFailed: return "这个字体暂时无法使用，请尝试其他字体文件。"
            }
        }
    }

    static func loadFonts() -> [ImportedChatFont] {
        guard let directory = try? fontDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        var fonts: [ImportedChatFont] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  let records = try? fontRecords(at: url) else { continue }
            do { try register(url, records: records) }
            catch { continue }
            fonts += records.filter { record in !fonts.contains(where: { $0.id == record.id }) }
        }
        return sorted(fonts)
    }

    static func importFont(from source: URL, existingFonts: [ImportedChatFont]) throws -> [ImportedChatFont] {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let fileExtension = source.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else { throw ImportError.unsupportedFile }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ImportError.unsupportedFile }
        if let size = values.fileSize, size >= maximumFileSize { throw ImportError.oversizedFile }

        let destination = try fontDirectory().appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        var keepFile = false
        defer { if !keepFile { try? FileManager.default.removeItem(at: destination) } }

        // Coordinate the read so fonts in iCloud and other File Provider apps
        // finish downloading before their scoped URL is released.
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            do { try FileManager.default.copyItem(at: readableURL, to: destination) }
            catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        let copiedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard copiedSize < maximumFileSize else { throw ImportError.oversizedFile }

        let records = try fontRecords(at: destination)
        let existing = records.compactMap { record in existingFonts.first(where: { $0.id == record.id }) }
        // Reimporting an existing font simply selects it; it never replaces it.
        if existing.count == records.count { return existing }
        guard existing.isEmpty,
              !records.contains(where: { UIFont(name: $0.postScriptName, size: 16) != nil }) else {
            throw ImportError.conflictingFont
        }
        try register(destination, records: records)
        keepFile = true
        return records
    }

    /// Removes the file that holds this face. A TTC can carry several faces,
    /// so every face from that file goes with it; returns their PostScript names.
    static func deleteFont(postScriptName: String) throws -> [String] {
        let directory = try fontDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        for url in urls where supportedExtensions.contains(url.pathExtension.lowercased()) {
            guard let records = try? fontRecords(at: url),
                  records.contains(where: { $0.postScriptName == postScriptName }) else { continue }
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            try FileManager.default.removeItem(at: url)
            return records.map(\.postScriptName)
        }
        return []
    }

    static func sorted(_ fonts: [ImportedChatFont]) -> [ImportedChatFont] {
        fonts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static func fontDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("TidalEcho/ImportedFonts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func fontRecords(at url: URL) throws -> [ImportedChatFont] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else { throw ImportError.invalidFont }
        let records = descriptors.map { descriptor in
            let font = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
            return ImportedChatFont(
                postScriptName: CTFontCopyPostScriptName(font) as String,
                displayName: CTFontCopyFullName(font) as String
            )
        }
        guard records.allSatisfy({ !$0.postScriptName.isEmpty }),
              Set(records.map(\.postScriptName)).count == records.count else { throw ImportError.invalidFont }
        return records
    }

    private static func register(_ url: URL, records: [ImportedChatFont]) throws {
        var registrationError: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError)
        let error = registrationError?.takeRetainedValue()
        if registered { return }
        if let error, CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue,
           records.allSatisfy({ UIFont(name: $0.postScriptName, size: 16) != nil }) { return }
        throw ImportError.registrationFailed
    }
}
