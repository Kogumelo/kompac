import Foundation

/// Encoding of the names inside the archive.
///
/// ZIPs made on Windows without the UTF-8 flag store names in the machine's code page:
/// CP437/CP850 (ZIP's "OEM" default, used by Explorer) or Windows-1252 (various programs).
/// 7zz for Mac does not convert these code pages (the `-mcp=` option changes neither listing nor
/// extraction, tested on 26.04): each byte that is not valid UTF-8 becomes the private-use
/// character U+EF00 + byte (0xF3 → U+EFF3), both in the listing and in the name written to disk.
/// From that we recover the original bytes and decode them with the chosen code page.
public enum NameEncoding: String, CaseIterable, Sendable, Identifiable {
    case automatic, cp437, cp850, windows1252, utf8

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: return NSLocalizedString("Automatic", comment: "Name encoding option")
        case .cp437: return NSLocalizedString("CP437 (DOS, ZIP default)", comment: "Name encoding option")
        case .cp850: return NSLocalizedString("CP850 (DOS Western Europe)", comment: "Name encoding option")
        case .windows1252: return "Windows-1252"
        case .utf8: return "UTF-8"
        }
    }

    public var shortLabel: String {
        switch self {
        case .automatic: return NSLocalizedString("Automatic", comment: "Name encoding option")
        case .cp437: return "CP437"
        case .cp850: return "CP850"
        case .windows1252: return "Windows-1252"
        case .utf8: return "UTF-8"
        }
    }

    var foundation: String.Encoding? {
        switch self {
        case .automatic, .utf8: return nil
        case .windows1252: return .windowsCP1252
        case .cp437: return Self.cf(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
        case .cp850: return Self.cf(CFStringEncoding(CFStringEncodings.dosLatin1.rawValue))
        }
    }

    private static func cf(_ e: CFStringEncoding) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(e))
    }
}

public enum NameDecoder {
    /// Private-use character 7zz uses in place of an invalid byte.
    static func rawByte(_ s: Unicode.Scalar) -> UInt8? {
        (0xEF80...0xEFFF).contains(s.value) ? UInt8(s.value - 0xEF00) : nil
    }

    /// The name has bytes that were not valid UTF-8.
    public static func hasRawBytes(_ s: String) -> Bool {
        s.unicodeScalars.contains { rawByte($0) != nil }
    }

    /// Original bytes of the name: U+EF80…U+EFFF characters become the byte again; the rest, UTF-8.
    public static func rawBytes(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            if let b = rawByte(scalar) { out.append(b) } else { out.append(contentsOf: String(scalar).utf8) }
        }
        return out
    }

    /// Name converted to the concrete encoding (not `automatic`).
    public static func convert(_ s: String, using encoding: NameEncoding) -> String {
        switch encoding {
        case .automatic:
            return s
        case .utf8:
            guard hasRawBytes(s) else { return s }
            // bytes that are still invalid become "�"
            return String(decoding: rawBytes(s), as: UTF8.self)
        default:
            // Only touch names that had non-UTF-8 bytes: a valid UTF-8 name was not stored
            // in the code page, and reinterpreting it would garble the accents.
            guard hasRawBytes(s), let enc = encoding.foundation else { return s }
            return String(data: Data(rawBytes(s)), encoding: enc) ?? s
        }
    }

    /// Picks the code page that yields the most plausible names in Portuguese.
    /// With no invalid byte at all, the names are already UTF-8.
    public static func detect<S: Sequence>(_ names: S) -> NameEncoding where S.Element == String {
        let suspicious = names.filter(hasRawBytes)
        guard !suspicious.isEmpty else { return .utf8 }
        // On a tie, CP850 (Windows Explorer in Portuguese) wins over CP437, and both over 1252.
        let candidates: [NameEncoding] = [.cp850, .cp437, .windows1252]
        var best = NameEncoding.cp850, bestScore = Int.min
        for c in candidates {
            var score = 0
            for name in suspicious.prefix(500) {
                score += plausibility(convert(name, using: c))
            }
            if score > bestScore { best = c; bestScore = score }
        }
        return best
    }

    /// Scores each non-ASCII character: an accented letter common in Portuguese scores higher; box
    /// drawing, Greek letters, math symbols and control characters count against.
    static func plausibility(_ s: String) -> Int {
        var score = 0
        for scalar in s.unicodeScalars where scalar.value >= 0x80 {
            if common.contains(scalar) { score += 3 } else if (0xC0...0xFF).contains(scalar.value) && scalar.value != 0xD7 && scalar.value != 0xF7 {
                score += 1
            } else if scalar == "º" || scalar == "ª" || scalar == "°" {
                score += 1
            } else {
                score -= 3
            }
        }
        return score
    }

    private static let common = Set("áàâãéêíóôõúüçÁÀÂÃÉÊÍÓÔÕÚÜÇ".unicodeScalars)
}
