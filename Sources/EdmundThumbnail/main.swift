// This target is an `.appex` bundle: its real entry point is Foundation's
// `NSExtensionMain`, wired via the `-e _NSExtensionMain` linker flag in
// Package.swift. SwiftPM still requires an entry file for an executable target,
// so this file exists but its top-level code never runs — the linker redirects
// the entry symbol before `main` is reached.
