import Foundation

enum DescriptorPreparation {
    static func prepare(in folderURL: URL, randomizedID: Int, provider: String) throws -> String? {
        let fileManager = FileManager.default
        if provider == "com.apple.MercuryPoster" {
            let identifierURL = folderURL.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
            guard
                let data = try? Data(contentsOf: identifierURL),
                let identifier = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                identifier.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil
            else {
                throw TemplateFailure(message: "Mercury descriptor identifier is missing or invalid.")
            }
            // Mercury chooses its renderer from this identifier (for example d23).
            // Keep its provider-owned contents.userInfo and suggestion metadata intact.
            return identifier
        }
        guard
            let enumerator = fileManager.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else {
            throw TemplateFailure(message: "Cannot inspect the extracted descriptor.")
        }
        var foundIdentifier = false
        while let fileURL = enumerator.nextObject() as? URL {
            let name = fileURL.lastPathComponent
            if name == "com.apple.posterkit.provider.descriptor.identifier" {
                try Data("\(randomizedID)".utf8).write(to: fileURL, options: .atomic)
                if fileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == folderURL.resolvingSymlinksInPath().path
                {
                    foundIdentifier = true
                }
            } else if name == "com.apple.posterkit.provider.contents.userInfo" || name.hasSuffix("Wallpaper.plist") {
                let data = try Data(contentsOf: fileURL)
                guard
                    var plist = try PropertyListSerialization.propertyList(
                        from: data, options: .mutableContainers, format: nil) as? [String: Any]
                else {
                    throw TemplateFailure(message: "Invalid wallpaper property list: \(name)")
                }
                let key =
                    name == "com.apple.posterkit.provider.contents.userInfo"
                    ? "wallpaperRepresentingIdentifier" : "identifier"
                plist[key] = randomizedID
                let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
                try updated.write(to: fileURL, options: .atomic)
            }
        }
        guard foundIdentifier else {
            throw TemplateFailure(message: "This archive does not contain a complete template descriptor.")
        }
        return nil
    }
}
