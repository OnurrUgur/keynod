import AppKit

// Invoked through a symlink named `keynod`: act as the command-line client and
// never start the GUI directly (it connects to the running app over keynod.sock).
if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "keynod" {
    CLI.run()
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
