import Foundation

/// devcontainer.json is "JSON with comments": strip `//` and `/* */` comments
/// and trailing commas so Foundation's strict parser accepts it.
public enum JSONC {
    public static func strip(_ text: String) -> String {
        removeTrailingCommas(removeComments(text))
    }

    static func removeComments(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var inString = false
        while i < s.count {
            let c = s[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < s.count { out.append(s[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2
                while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    static func removeTrailingCommas(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var inString = false
        while i < s.count {
            let c = s[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < s.count { out.append(s[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "," {
                var j = i + 1
                while j < s.count, CharacterSet.whitespacesAndNewlines.contains(s[j]) { j += 1 }
                if j < s.count, s[j] == "}" || s[j] == "]" { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }
}
