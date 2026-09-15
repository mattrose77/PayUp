import Foundation

/// Reads the backend credentials that the build injected from
/// Config/Secrets.xcconfig. Nothing here is hardcoded in source, so the
/// publishable key can be rotated without touching Swift.
enum Config {
    static var supabaseURL: URL {
        guard let host = value(for: "SupabaseHost"), !host.isEmpty else {
            fatalError("SupabaseHost missing — copy Config/Secrets.example.xcconfig to Config/Secrets.xcconfig")
        }
        // The scheme is spliced on here because "//" starts a comment in xcconfig.
        guard let url = URL(string: "https://\(host)") else {
            fatalError("SupabaseHost is not a valid host: \(host)")
        }
        return url
    }

    static var supabasePublishableKey: String {
        guard let key = value(for: "SupabasePublishableKey"), !key.isEmpty else {
            fatalError("SupabasePublishableKey missing — see Config/Secrets.example.xcconfig")
        }
        return key
    }

    private static func value(for key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
