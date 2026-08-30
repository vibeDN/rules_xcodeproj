import Foundation

// MARK: - Helpers

enum PathKey: String {
    case emitModulePath = "-emit-module-path"
    case emitObjCHeaderPath = "-emit-objc-header-path"
    case outputFileMap = "-output-file-map"
    case sdk = "-sdk"
}

func processArgs(
    _ args: [String]
) async throws -> (
    isPreviewThunk: Bool,
    isWMO: Bool,
    paths: [PathKey: URL]
) {
    var isPreviewThunk = false
    var isWMO = false
    var paths: [PathKey: URL] = [:]

    var previousArg: String?
    func processArg(_ arg: String) {
        if let rawPathKey = previousArg,
            let key = PathKey(rawValue: rawPathKey)
        {
            paths[key] = URL(fileURLWithPath: arg)
            previousArg = nil
            return
        }

        if arg == "-wmo" || arg == "-whole-module-optimization" {
            isWMO = true
        } else if arg.hasSuffix(".preview-thunk.swift") {
            isPreviewThunk = true
        } else {
            previousArg = arg
        }
    }

    for arg in args {
        if arg.hasPrefix("@") {
            let argumentFileURL
                = URL(fileURLWithPath: String(arg.dropFirst()))
            for try await line in argumentFileURL.lines {
                if line.hasPrefix(#"""#) && line.hasSuffix(#"""#) {
                    processArg(String(line.dropFirst().dropLast()))
                } else {
                    processArg(String(line))
                }
            }
        } else {
            processArg(arg)
        }
    }

    return (
        !paths.keys.contains(.outputFileMap) && isPreviewThunk,
        isWMO,
        paths
    )
}

extension URL {
    mutating func touch() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            // MARK: ViboGram - bugfix for MobileNativeFoundation/rules_xcodeproj#3183.
            // `createFile`'s Bool result was previously discarded, and the parent
            // directory was never created first. On a large target graph the
            // Objects-normal/arm64 directory for this target isn't always created
            // yet by the time Xcode invokes this stub as the target's compiler,
            // so createFile silently failed, this function returned normally
            // anyway, and Xcode believed CompileSwiftSources had produced the
            // .swiftmodule -- only for the later native "Copy" build step (which
            // copies it into the framework's Modules folder) to fail with ENOENT,
            // since the file was never actually created. Creating the parent
            // directory first and surfacing a real failure instead of silently
            // continuing turns that into a loud, attributable error instead of a
            // confusing downstream ENOENT three steps later.
            try fileManager.createDirectory(
                at: deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard fileManager.createFile(atPath: path, contents: nil) else {
                throw NSError(
                    domain: "swiftc_stub.touch",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "createFile failed for \(path)",
                    ]
                )
            }
        } else {
            var resourceValues = URLResourceValues()
            resourceValues.contentModificationDate = Date()
            try setResourceValues(resourceValues)
        }
    }
}

/// Touch the Xcode-required `.d` files
func touchDepsFiles(isWMO: Bool, paths: [PathKey: URL]) throws {
    guard let outputFileMapPath = paths[PathKey.outputFileMap] else { return }

    if isWMO {
        // Xcode 26 beta 3 changed the naming convention for .d files of WMO modules to
        // use a suffix of "-primary" instead of "-master". Support both for now.
        let basePath = outputFileMapPath.path.dropLast("-OutputFileMap.json".count)
        for suffix in ["-master", "-primary"] {
            let dPath = "\(basePath)\(suffix).d"
            var url = URL(fileURLWithPath: dPath)
            try url.touch()
        }
    } else {
        let data = try Data(contentsOf: outputFileMapPath)
        let outputFileMapRaw = try JSONSerialization.jsonObject(
            with: data,
            options: []
        )
        guard let outputFileMap = outputFileMapRaw as? [String: [String: Any]]
        else {
            return
        }

        for entry in outputFileMap.values {
            guard let dPath = entry["dependencies"] as? String else {
                continue
            }
            var url = URL(fileURLWithPath: dPath)
            try url.touch()
        }
    }
}

/// Touch the Xcode-required `.swift{module,doc,sourceinfo}` files
func touchSwiftmoduleArtifacts(paths: [PathKey: URL]) throws {
    if var swiftmodulePath = paths[PathKey.emitModulePath] {
        var swiftdocPath = swiftmodulePath.deletingPathExtension()
            .appendingPathExtension("swiftdoc")
        var swiftsourceinfoPath = swiftmodulePath.deletingPathExtension()
            .appendingPathExtension("swiftsourceinfo")
        var swiftinterfacePath = swiftmodulePath.deletingPathExtension()
            .appendingPathExtension("swiftinterface")

        try swiftmodulePath.touch()
        try swiftdocPath.touch()
        try swiftsourceinfoPath.touch()
        try swiftinterfacePath.touch()
    }

    if var generatedHeaderPath = paths[PathKey.emitObjCHeaderPath] {
        try generatedHeaderPath.touch()
    }
}

// MARK: - Parseable output protocol (-parseable-output)

// MARK: ViboGram - investigating MobileNativeFoundation/rules_xcodeproj#3183.
// Xcode passes -parseable-output to every real swiftc invocation and reads a
// stream of length-prefixed JSON messages from stdout describing exactly
// what a compile task produced and when (see
// https://github.com/swiftlang/swift/blob/main/docs/DriverParseableOutput.md).
// This stub never spoke that protocol -- it only touches files and exits.
// Live debugging showed the native "Copy .swiftmodule" step can run before
// this stub's touch() finishes even when the file is pre-created in an
// earlier, unrelated build phase, which rules out ordinary phase-ordering as
// the mechanism. Emitting a well-formed "began"/"finished" pair -- the same
// signal a real compile gives -- is the next thing worth trying: if Xcode's
// build system uses this stream (rather than, or in addition to, actual
// filesystem state) to decide when a task's declared outputs are ready,
// staying silent on it could easily explain the gap.
func emitParseableMessage(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
        let jsonString = String(data: data, encoding: .utf8)
    else {
        return
    }
    // Wire format is "<byte length>\n{json}\n" -- both lines go through the
    // same buffered `print` so they can't land out of order relative to
    // each other (mixing this with a raw FileHandle write on the same fd
    // risks exactly that).
    print(data.count)
    print(jsonString)
}

func emitCompileBegan(pid: Int32, args: [String], paths: [PathKey: URL]) {
    var outputs: [[String: String]] = []
    if let swiftmodulePath = paths[PathKey.emitModulePath] {
        outputs.append(["type": "swiftmodule", "path": swiftmodulePath.path])
        let base = swiftmodulePath.deletingPathExtension()
        outputs.append([
            "type": "swiftdoc",
            "path": base.appendingPathExtension("swiftdoc").path,
        ])
        outputs.append([
            "type": "swiftsourceinfo",
            "path": base.appendingPathExtension("swiftsourceinfo").path,
        ])
        outputs.append([
            "type": "swiftinterface",
            "path": base.appendingPathExtension("swiftinterface").path,
        ])
    }
    if let headerPath = paths[PathKey.emitObjCHeaderPath] {
        outputs.append(["type": "objc-header", "path": headerPath.path])
    }

    emitParseableMessage([
        "kind": "began",
        "name": "compile",
        "pid": Int(pid),
        "process": ["real_pid": Int(pid)],
        "outputs": outputs,
        "command_executable": args.first ?? "swiftc",
        "command_arguments": Array(args.dropFirst()),
    ])
}

func emitCompileFinished(pid: Int32, exitStatus: Int32) {
    emitParseableMessage([
        "kind": "finished",
        "name": "compile",
        "pid": Int(pid),
        "exit-status": Int(exitStatus),
        "process": ["real_pid": Int(pid)],
    ])
}

func runSubProcess(executable: String, args: [String]) throws -> Int32 {
    let task = Process()
    task.launchPath = executable
    task.arguments = args
    try task.run()
    task.waitUntilExit()
    return task.terminationStatus
}

func handleXcodePreviewThunk(args: [String], paths: [PathKey: URL]) throws -> Never {
    guard let sdkPath = paths[PathKey.sdk]?.path else {
        fputs(
            "error: No such argument '-sdk'. Using /usr/bin/swiftc.",
            stderr
        )
        exit(1)
    }

    // TODO: Make this work with custom toolchains
    // We could produce this file at the start of the build?
    let fullRange = NSRange(sdkPath.startIndex..., in: sdkPath)
    let matches = try NSRegularExpression(
        pattern: #"(.*?/Contents/Developer)/.*"#
    ).matches(in: sdkPath, range: fullRange)
    guard let match = matches.first,
        let range = Range(match.range(at: 1), in: sdkPath)
    else {
        fputs(
            """
error: Failed to parse DEVELOPER_DIR from '-sdk'. Using /usr/bin/swiftc.
""",
            stderr
        )
        exit(1)
    }
    let developerDir = sdkPath[range]

    try exit(runSubProcess(
        executable: """
\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
""",
        args: Array(args.dropFirst())
    ))
}

// MARK: - Main

let args = CommandLine.arguments
// Xcode 16.0 Beta 3 began using "--version" over "-v". Support both.
if args.count == 2, args.last == "--version" || args.last == "-v" {
    guard let path = ProcessInfo.processInfo.environment["PATH"] else {
        fputs("error: PATH not set", stderr)
        exit(1)
    }

    // /Applications/Xcode-15.0.0-Beta.app/Contents/Developer/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin -> /Applications/Xcode-15.0.0-Beta.app/Contents/Developer/usr/bin
    let pathComponents = path.split(separator: ":", maxSplits: 1)
    let xcodeBinPath = pathComponents[0]
    guard xcodeBinPath.hasSuffix("/Contents/Developer/usr/bin") else {
        fputs("error: Xcode based bin PATH not set", stderr)
        exit(1)
    }

    // /Applications/Xcode-15.0.0-Beta.app/Contents/Developer/usr/bin -> /Applications/Xcode-15.0.0-Beta.app/Contents/Developer
    let developerDir = xcodeBinPath.dropLast(8)

    // TODO: Make this work with custom toolchains
    let swiftcPath = """
\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
"""

    // args.last allows passing in -v (Xcode < 16b3) and --version (>= 16b3)
    try exit(runSubProcess(executable: swiftcPath, args: [args.last!]))
}

let (
    isPreviewThunk,
    isWMO,
    paths
) = try await processArgs(args)

guard !isPreviewThunk else {
    // Pass through for Xcode Preview thunk compilation
    try handleXcodePreviewThunk(args: args, paths: paths)
}

// MARK: ViboGram - see emitParseableMessage's doc comment. Only speak the
// protocol when Xcode actually asked for it (every real BwB compile
// invocation passes this), so non-parseable-output call shapes (there
// shouldn't be any left at this point, but just in case) don't get
// unexpected stdout content.
let useParseableOutput = args.contains("-parseable-output")
let pid = ProcessInfo.processInfo.processIdentifier
if useParseableOutput {
    emitCompileBegan(pid: pid, args: args, paths: paths)
}

do {
    try touchDepsFiles(isWMO: isWMO, paths: paths)
    try touchSwiftmoduleArtifacts(paths: paths)
} catch {
    if useParseableOutput {
        emitCompileFinished(pid: pid, exitStatus: 1)
    }
    throw error
}

if useParseableOutput {
    emitCompileFinished(pid: pid, exitStatus: 0)
}
