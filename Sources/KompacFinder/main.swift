import Foundation

// An app extension starts in NSExtensionMain, which instantiates the principal class named in the
// appex's Info.plist (KompacFinder.FinderSync) and serves the Finder's requests.
@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

exit(NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
