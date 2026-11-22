import Foundation

/// Strips OAuth secrets from any text before it is logged or shown in diagnostics.
public enum LogRedactor {
    private static let patterns: [String] = [
        #"ya29\.[A-Za-z0-9._\-]+"#,                       // Google access tokens
        #"1//[A-Za-z0-9._\-]+"#,                           // Google refresh tokens
        #"(?i)(code|access_token|refresh_token|id_token|client_secret|code_verifier)=[^&\s"]+"#,
        #"(?i)"(access_token|refresh_token|id_token|client_secret)"\s*:\s*"[^"]*""#,
        #"(?i)Bearer\s+[A-Za-z0-9._\-]+"#,
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "[REDACTED]")
        }
        return result
    }
}
