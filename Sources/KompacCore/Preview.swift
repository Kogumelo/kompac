import Foundation

/// Decides whether the first bytes of an item are text and decodes them.
public enum PreviewText {
    /// `nil` = binary. Accepts UTF-8 and, if it is not UTF-8, Windows-1252, common in text coming from
    /// Windows. `truncated`: reading stopped at the limit, and the last character may have been cut.
    public static func decode(_ data: Data, truncated: Bool = false) -> String? {
        if data.isEmpty { return "" }
        let sample = data.prefix(8192)
        if sample.contains(0) { return nil }
        var control = 0
        for b in sample where b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D && b != 0x0C && b != 0x1B {
            control += 1
        }
        if control * 50 > sample.count { return nil }

        var bytes = data
        // A UTF-16 BOM is text, but not UTF-8; leave it to Foundation.
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: bytes, encoding: .utf16)
        }
        for _ in 0..<(truncated ? 4 : 1) {
            if let s = String(data: bytes, encoding: .utf8) { return s }
            guard !bytes.isEmpty else { break }
            bytes = bytes.dropLast()
        }
        return String(data: data, encoding: .windowsCP1252)
    }

    /// Description of the kind from the name, for items that are not text.
    public static func kind(of name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "": return NSLocalizedString("File", comment: "Preview: kind of an item without extension")
        case "fdb", "gdb", "db", "sqlite", "mdb", "accdb":
            return String(format: NSLocalizedString("Database (.%@)", comment: "Preview: item kind; %@ = file extension"), ext)
        case "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "webp":
            return String(format: NSLocalizedString("Image (.%@)", comment: "Preview: item kind; %@ = file extension"), ext)
        case "pdf": return NSLocalizedString("PDF document", comment: "Preview: item kind")
        case "doc", "docx", "odt", "rtf":
            return String(format: NSLocalizedString("Text document (.%@)", comment: "Preview: item kind; %@ = file extension"), ext)
        case "xls", "xlsx", "ods", "csv":
            return String(format: NSLocalizedString("Spreadsheet (.%@)", comment: "Preview: item kind; %@ = file extension"), ext)
        case "zip", "rar", "7z", "gz", "tgz", "bz2", "xz", "zst", "tar":
            return String(format: NSLocalizedString("Compressed archive (.%@)", comment: "Preview: item kind; %@ = file extension"), ext)
        case "exe", "dll", "app", "dylib", "so":
            return String(format: NSLocalizedString("Program (.%@)", comment: "Preview: item kind; %@ = file extension"), ext)
        case "mp3", "wav", "m4a", "flac", "ogg":
            return String(format: NSLocalizedString("Audio (.%@)", comment: "Preview: item kind; %@ = file extension"), ext)
        case "mp4", "mov", "avi", "mkv":
            return String(format: NSLocalizedString("Video (.%@)", comment: "Preview: item kind; %@ = file extension"), ext)
        default:
            return String(format: NSLocalizedString(".%@ file", comment: "Preview: kind of an item with an unknown extension; %@ = file extension"), ext)
        }
    }
}
