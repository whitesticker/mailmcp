import Foundation

enum CursorInstaller {
    static func cliURL() -> URL? { MCPClientInstaller.cliURL() }
    static func install() throws -> String { try MCPClientInstaller.install(.cursor) }
    static func snippet() -> String { MCPClientInstaller.snippet() }
}
