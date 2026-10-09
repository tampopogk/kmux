import Foundation

/// Which product this build is: kmux itself, or a product built on it (Kanna
/// ships its own copy as Kanna.app). The brand names the socket folder and
/// files and the environment variables, so the two never talk to each other's
/// windows. The build script writes it into Info.plist; plain builds and tests
/// are kmux.
public struct Brand: Sendable, Equatable {
    /// Lower case: the socket folder and files (`kmux`, `kmux.sock`).
    public let id: String
    /// What the user sees: window title, app menu.
    public let displayName: String

    public static let kmux = Brand(id: "kmux", displayName: "kmux")

    public static let current: Brand = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let id = info["KmuxBrand"] as? String, !id.isEmpty else { return .kmux }
        return Brand(id: id, displayName: info["CFBundleName"] as? String ?? id)
    }()

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    /// `KMUX_SOCKET` for kmux, `KANNA_SOCKET` for Kanna.
    public func variable(_ name: String) -> String { "\(id.uppercased())_\(name)" }
}
