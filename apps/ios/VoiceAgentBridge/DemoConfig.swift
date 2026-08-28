import Foundation

/// Development-only convenience values for Knock Knock.
///
/// Release builds intentionally contain no demo credentials and no fixed LAN
/// address. A production endpoint can be supplied through the
/// `KNOCK_API_BASE_URL` bundle setting or entered by the user in Settings.
enum DemoConfig {
    enum BuildChannel: Equatable {
        case development
        case staging
        case production
    }

    static let stagingApiBase = "https://knock-knock-backend-staging.wch-klaus.workers.dev"
    static let productionApiBase = "https://knock-knock-backend-production.wch-klaus.workers.dev"

    static var buildChannel: BuildChannel {
        #if KNOCK_STAGING
        return .staging
        #elseif DEBUG
        return .development
        #else
        return .production
        #endif
    }

    static var requiresHTTPS: Bool {
        buildChannel != .development
    }

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

    /// Recognize an old local-fixture email persisted by pre-release builds
    /// without embedding the fixture identity in a Release binary.
    static func isLegacyDemoEmail(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        #if DEBUG
        return normalized == email.lowercased()
        #else
        return normalized.hasSuffix("@local.test")
        #endif
    }

    static var defaultApiBase: String {
        defaultApiBase(
            channel: buildChannel,
            bundled: bundledApiBase,
            isSimulator: isSimulatorBuild
        )
    }

    static func defaultApiBase(
        channel: BuildChannel,
        bundled: String?,
        isSimulator: Bool
    ) -> String {
        if channel == .staging {
            return stagingApiBase
        }
        if let bundled = normalizedConfiguredApiBase(bundled) {
            return bundled
        }
        switch channel {
        case .development:
            // Only the simulator may safely assume the Mac loopback address.
            return isSimulator ? "http://127.0.0.1:8787" : ""
        case .staging:
            return stagingApiBase
        case .production:
            return productionApiBase
        }
    }

    /// Returns an explicit endpoint supplied by a local Debug/UI-test launch.
    ///
    /// This must be checked before persisted settings: a simulator may retain
    /// an older `vab.apiBase` value and silently send a test run to the wrong
    /// Worker. Release builds intentionally ignore process environment values.
    static func runtimeApiBaseOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        channel: BuildChannel = buildChannel
    ) -> String? {
        guard channel == .development else { return nil }
        for key in ["KNOCK_UI_TEST_API_BASE_URL", "KNOCK_API_BASE_URL"] {
            guard let value = normalizedConfiguredApiBase(environment[key]) else { continue }
            return value
        }
        return nil
    }

    /// Resolves the launch endpoint under an explicit build policy.
    ///
    /// Staging is intentionally a compile-time lock. Bundle substitutions,
    /// process environment, persisted Settings values, and simulator defaults
    /// are all untrusted inputs for that channel.
    static func resolvedApiBase(
        persisted: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        channel: BuildChannel = buildChannel,
        bundled: String? = bundledApiBase,
        isSimulator: Bool = isSimulatorBuild
    ) -> String {
        switch channel {
        case .staging:
            return stagingApiBase
        case .development:
            if let runtime = runtimeApiBaseOverride(
                environment: environment,
                channel: channel
            ) {
                return runtime
            }
            if !shouldIgnorePersistedDevelopmentApiBase(
                persisted: persisted,
                bundledDefault: defaultApiBase(
                    channel: channel,
                    bundled: bundled,
                    isSimulator: isSimulator
                )
            ), let persisted = normalizedConfiguredApiBase(persisted) {
                return persisted
            }
            return defaultApiBase(
                channel: channel,
                bundled: bundled,
                isSimulator: isSimulator
            )
        case .production:
            if let persisted = normalizedConfiguredApiBase(persisted),
               isValidApiBase(persisted, requireHTTPS: true),
               !isLegacyDevelopmentApiBase(persisted, requireHTTPS: true)
            {
                return persisted
            }
            return defaultApiBase(
                channel: channel,
                bundled: bundled,
                isSimulator: isSimulator
            )
        }
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

    /// Staging is a Debug configuration, so leftover LAN/localhost UserDefaults
    /// used to beat the bundled HTTPS Worker and leave the phone Offline.
    /// A bundled HTTPS endpoint always wins over that leftover development URL.
    /// An explicit HTTPS host the user typed in Settings is kept.
    static func shouldIgnorePersistedDevelopmentApiBase(
        persisted: String?,
        bundledDefault: String = defaultApiBase
    ) -> Bool {
        isValidApiBase(bundledDefault, requireHTTPS: true)
            && isLegacyDevelopmentApiBase(persisted, requireHTTPS: false)
    }

    private static var bundledApiBase: String? {
        Bundle.main.object(forInfoDictionaryKey: "KNOCK_API_BASE_URL") as? String
    }

    private static var isSimulatorBuild: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static func normalizedConfiguredApiBase(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
