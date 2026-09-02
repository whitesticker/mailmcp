import Foundation

#if MAILMCP_CLI
@main
struct MailMCPCLI {
    static func main() {
        MCPShim.run()
    }
}
#endif
