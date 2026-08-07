import Foundation

/// Development-only convenience values for Knock Knock.
///
/// Release builds intentionally contain no demo credentials and no fixed LAN
/// address. A production endpoint can be supplied through the
/// `KNOCK_API_BASE_URL` bundle setting or entered by the user in Settings.
enum DemoConfig {
    static let productionApiBase = "https://knock-knock-backend-production.wch-klaus.workers.dev"
    static let legacyDemoEmail = "e2e-1785931570@local.test"

    static var buildLabel: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build, !build.isEmpty, !build.hasPrefix("$(") else {
            return "build-unknown"
        }
        return "build-\(build)"
    }

    #if DEBUG
    static let email = "e2e-1785931570@local.test"
    static let password = "password123"
    #else
    // Keep the production binary free of local test credentials.
    static let email = ""
    static let password = ""
    #endif

    static var defaultApiBase: String {
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "KNOCK_API_BASE_URL") as? String {
            let trimmed = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("$(") {
                return trimmed
            }
        }

        #if DEBUG
        #if targetEnvironment(simulator)
        // Only the simulator may safely assume the Mac loopback address.
        return "http://127.0.0.1:8787"
        #else
        // A physical phone must use the current Mac LAN address supplied by the user.
        return ""
        #endif
        #else
        return productionApiBase
        #endif
    }

    /// Validates an API base URL for the current build policy.
    ///
    /// Debug builds may use a local HTTP bridge. Distribution builds must
    /// use HTTPS so a persisted development address can never be used by
    /// accident after a TestFlight update.
    static func isValidApiBase(_ raw: String?, requireHTTPS: Bool) -> Bool {
        guard let raw else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("$("),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty
        else {
            return false
        }
        if requireHTTPS {
            return scheme == "https"
        }
        return scheme == "http" || scheme == "https"
    }

    /// Identifies an endpoint that a Release/TestFlight build must not keep
    /// across an app update. A user-entered HTTPS host is preserved.
    static func isLegacyDevelopmentApiBase(_ raw: String?, requireHTTPS: Bool) -> Bool {
        guard isValidApiBase(raw, requireHTTPS: requireHTTPS),
              let raw,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased()
        else {
            return raw != nil
        }

        if host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "::1" || host.hasSuffix(".local") {
            return true
        }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        if octets[0] == 10 || octets[0] == 192 && octets[1] == 168 {
            return true
        }
        return octets[0] == 172 && (16...31).contains(octets[1])
    }
}
