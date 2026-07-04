import Foundation

/// The pure string-building for the "Work on in Claude Code" launch (#35): the
/// `claude` seed, the shell command run in the new iTerm2 session, and the
/// AppleScript that opens the window. Kept out of the app shell so the escaping
/// - the correctness-and-injection risk - is testable without a terminal. The
/// shell (`ClaudeCodeService`) owns only the actual iTerm2 launch.
public enum ClaudeCodeLaunch {
    /// The seed passed to `claude` so it starts on the task: the title plus the
    /// Notion URL when there is one, degrading to title-only for a pre-#21
    /// cached snapshot that has no URL.
    public static func seed(title: String, url: String?) -> String {
        if let url, !url.isEmpty {
            return "Help with: \(title) (\(url))"
        }
        return "Help with: \(title)"
    }

    /// The one command written into the new iTerm2 session: cd into the
    /// workspace directory, then launch `claude` with the seed. Both the
    /// directory and the seed are single-quote-escaped for the shell, so a title
    /// with quotes, `$`, or backticks can neither break the command nor inject
    /// into it. A leading `~` in the directory is expanded first, because the
    /// shell does not expand a tilde inside single quotes; `home` is injectable
    /// so the expansion is testable.
    public static func shellCommand(
        workspaceDirectory: String, seed: String, home: String = NSHomeDirectory()
    ) -> String {
        let expanded = expandingTilde(workspaceDirectory, home: home)
        return "cd \(singleQuoted(expanded)) && claude \(singleQuoted(seed))"
    }

    /// The full AppleScript that opens a new iTerm2 window and runs `command`
    /// in it (#35), using iTerm2's modern scripting API. The command is embedded
    /// as an AppleScript string literal, so it is escaped for that context too
    /// (`\` and `"`) on top of the shell escaping already in `command`.
    public static func iTermScript(command: String) -> String {
        """
        tell application "iTerm"
            activate
            create window with default profile
            tell current session of current window
                write text \(appleScriptLiteral(command))
            end tell
        end tell
        """
    }

    /// POSIX single-quote escaping: wrap in single quotes and replace each
    /// embedded single quote with the `'\''` idiom (close, escaped quote,
    /// reopen). Nothing inside single quotes is special to the shell, so this is
    /// injection-proof for arbitrary content.
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a string for an AppleScript double-quoted literal: backslashes
    /// first (so the escapes we add aren't re-escaped), then double quotes.
    static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    /// Expand a leading `~` or `~/` to the home directory. Only a leading tilde
    /// is expanded (matching shell semantics); a tilde elsewhere is left alone.
    static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}
