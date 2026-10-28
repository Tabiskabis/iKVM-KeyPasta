// iKVM-KeyPasta launcher ("IPMIView+iKVM KeyPasta launcher.app") — a stable macOS app bundle that
// starts IPMIView's KVM console with the Java agent and (optionally) a relaxed TLS check for BMCs
// with an expired iKVM cert.
//
// Its purpose beyond the GUI: it is ONE fixed app identity. Grant Accessibility, Local Network
// and the firewall to this app once; the viewer (java) and the
// tunnel (stunnel) run as its children and inherit the grant, so nothing re-prompts.
//
// All the real work lives in the bundled ipmiview-keypasta.sh; this app only collects the
// paths/checkbox and runs that script with them as environment variables.

import SwiftUI
import AppKit
import Darwin
import UniformTypeIdentifiers
import Carbon.HIToolbox

// MARK: - glob helper
func globFiles(_ pattern: String) -> [String] {
    var g = glob_t()
    defer { globfree(&g) }
    guard glob(pattern, 0, nil, &g) == 0 else { return [] }
    var out: [String] = []
    for i in 0..<Int(g.gl_pathc) {
        if let c = g.gl_pathv[i] { out.append(String(cString: c)) }
    }
    return out
}

let HOME = NSHomeDirectory()

// MARK: - model
final class Model: ObservableObject {
    @Published var ipmiview: String  { didSet { save("ipmiview", ipmiview) } }
    @Published var intelJava: String { didSet { save("intelJava", intelJava) } }
    @Published var javawsPath: String { didSet { save("javawsPath", javawsPath) } }
    @Published var disableTLS: Bool  { didSet { UserDefaults.standard.set(disableTLS, forKey: "ignoreExpiredCert") } }
    @Published var useContainer: Bool { didSet { UserDefaults.standard.set(useContainer, forKey: "useContainer") } }
    // Container: each iKVM viewer IPMIView starts in a browser tab of its own (see watchViewerTabs)
    @Published var viewerTabs: Bool { didSet { UserDefaults.standard.set(viewerTabs, forKey: "viewerTabs") } }
    // Where the container's consoles open: in the VNC app (vncChoice) if there is one, else in the
    // browser (browserChoice); Option-click: the other one.
    // vncChoice: "auto" (TigerVNC Viewer if installed, else none), "none", "tiger",
    // "app:<path>" (opened with vnc://), "command" (vncCommand: ${HOST} ${VNCPORT}).
    @Published var vncChoice: String { didSet { vncChoiceChanged(oldValue) } }
    @Published var vncCommand: String { didSet { save("vncCommand", vncCommand) } }
    @Published var customVNCApps: [String] { didSet { UserDefaults.standard.set(customVNCApps, forKey: "customVNCApps") } }
    // browserChoice: "auto" (a Chromium browser, else the default browser), "default", "app:<path>",
    // "command" (browserCommand: ${URL} = the browser view)
    @Published var browserChoice: String { didSet { browserChoiceChanged(oldValue) } }
    @Published var browserCommand: String { didSet { save("browserCommand", browserCommand) } }
    @Published var customBrowsers: [String] { didSet { UserDefaults.standard.set(customBrowsers, forKey: "customBrowsers") } }
    // The container's desktops (run.sh --lan, VNC_PASSWORD): on this Mac only, no password and VNC
    // apps may give any; else the password (vncPassword). Not on this Mac only: always the
    // password. For containers started afterwards.
    @Published var localOnly: Bool {
        didSet {
            UserDefaults.standard.set(localOnly, forKey: "localOnly")
            if !localOnly && acceptAnyPassword { acceptAnyPassword = false }
        }
    }
    @Published var acceptAnyPassword: Bool { didSet { UserDefaults.standard.set(acceptAnyPassword, forKey: "acceptAnyPassword") } }
    @Published var vncPassword: String { didSet { Model.savePassword(vncPassword) } }
    var passwordNeeded: Bool { !localOnly || !acceptAnyPassword }
    // The containers' keyboard layout (X, setxkbmap): "auto" (from the Mac's input source,
    // containerLayout) or one of containerLayouts. For the containers started afterwards.
    @Published var containerLayoutChoice: String { didSet { save("containerLayout", containerLayoutChoice) } }
    var effectiveContainerLayout: String { containerLayoutChoice == "auto" ? Model.containerLayout : containerLayoutChoice }
    @Published var isoDir: String { didSet { save("isoDir", isoDir) } }
    @Published var screencapDir: String { didSet { save("screencapDir", screencapDir) } }
    @Published var log = ""
    // What's running: IPMIView only once at a time; any number of .jnlp viewers, also next to it.
    enum RunKind { case ipmiview, jnlp, container }
    @Published var ipmiviewRunning = false
    @Published var jnlpRunning = 0
    @Published var containerBusy = false
    // the container start in progress (containerBusy) is IPMIView's, not a .jnlp's
    @Published var busyWithIPMIView = false
    // IPMIView's container started (from the click on, its build included) or running: what it
    // takes at its start is locked in Preferences
    var ipmiviewContainerActive: Bool { containerRunning || (containerBusy && busyWithIPMIView) }
    // any container starting or running (IPMIView's or a .jnlp's)
    var anyContainerActive: Bool { containerRunning || containerBusy || !jnlpConsoles.isEmpty }
    var anyRunning: Bool { ipmiviewRunning || jnlpRunning > 0 || containerBusy }
    // something starting (IPMIView, a .jnlp, a container), until its window or console is there:
    // the throbber next to the log's header, the only one
    var starting: Bool { containerBusy || launchingIPMIView || launchingJnlp > 0 }
    @Published var containerRunning = false {
        didSet { if !containerRunning { viewerTabPorts = []; viewerNames = [:]; stoppingViewers = [] } }
    }
    // viewers asked to end (their Stop clicked), until their port is gone: a throbber for Stop
    @Published var stoppingViewers = Set<Int>()
    // IPMIView's iKVM viewers in tabs of their own (ports 6101-6199, see watchViewerTabs) and their
    // BMCs (the container's /tmp/viewer-names/N), listed under IPMIView's container
    @Published var viewerTabPorts: [Int] = []
    @Published var viewerNames: [Int: String] = [:]
    // How IPMIView's console was opened last (true: a VNC app): its viewers' tabs open the same
    // way. nil (never yet): as set in Preferences.
    var ipmiviewViaVNC: Bool? {
        get { UserDefaults.standard.object(forKey: "ipmiviewViaVNC") as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: "ipmiviewViaVNC") }
    }
    var viewersViaVNC: Bool { ipmiviewViaVNC ?? (vncTarget != nil) }
    // Starting, until its window (native: the app named "IPMIView"/"iKVM Viewer" in the Dock) or
    // its console (container) is there: a throbber instead of the button's symbol
    @Published var launchingIPMIView = false
    @Published var launchingJnlp = 0
    // .jnlp consoles in containers of their own (ikvm-jnlp-PORT), next to IPMIView's: their ports
    @Published var jnlpConsoles: [Int] = []

    private func save(_ k: String, _ v: String) { UserDefaults.standard.set(v, forKey: k) }

    init() {
        let d = UserDefaults.standard
        ipmiview  = d.string(forKey: "ipmiview")  ?? ""
        intelJava = d.string(forKey: "intelJava") ?? ""
        javawsPath = d.string(forKey: "javawsPath") ?? ""
        isoDir = d.string(forKey: "isoDir") ?? ""
        screencapDir = d.string(forKey: "screencapDir") ?? ""
        disableTLS = d.object(forKey: "ignoreExpiredCert") as? Bool ?? false
        let storedContainer = d.object(forKey: "useContainer") as? Bool
        useContainer = storedContainer ?? false
        viewerTabs = d.object(forKey: "viewerTabs") as? Bool ?? true
        browserChoice = d.string(forKey: "browserChoice") ?? "auto"
        browserCommand = d.string(forKey: "browserCommand") ?? ""
        vncChoice = d.string(forKey: "vncChoice") ?? "auto"
        vncCommand = d.string(forKey: "vncCommand") ?? ""
        customBrowsers = d.stringArray(forKey: "customBrowsers") ?? []
        customVNCApps = d.stringArray(forKey: "customVNCApps") ?? []
        let lo = d.object(forKey: "localOnly") as? Bool ?? true
        localOnly = lo
        acceptAnyPassword = lo && (d.object(forKey: "acceptAnyPassword") as? Bool ?? true)
        vncPassword = Model.loadPassword()
        containerLayoutChoice = d.string(forKey: "containerLayout") ?? "auto"
        detectIPMIView(force: false)
        detectIntelJava(force: false)
        // First run only: default to container mode when native can't work here — Apple Silicon
        // with no Intel Java or no Rosetta — as long as a container runtime is installed.
        if storedContainer == nil {
            let nativeUnlikely = Model.isAppleSilicon && (intelJava.isEmpty || !Model.rosettaInstalled)
            if nativeUnlikely && Model.dockerAvailable() { useContainer = true }
        }
        // a native start ends with its window: java-launcher's copies are named "IPMIView" and
        // "iKVM Viewer" (java-name.sh)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.localizedName == "IPMIView" { self.launched(ipmiview: true) }
            if app.localizedName == "iKVM Viewer" { self.launched(ipmiview: false) }
        }
    }

    // A start begins (the throbber), at most 90 s
    func launching(ipmiview: Bool) {
        if ipmiview { launchingIPMIView = true } else { launchingJnlp += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self else { return }
            if ipmiview { self.launchingIPMIView = false } else { self.launchingJnlp = max(0, self.launchingJnlp - 1) }
        }
    }

    // ... and is done (or failed)
    func launched(ipmiview: Bool) {
        if ipmiview { launchingIPMIView = false } else { launchingJnlp = max(0, launchingJnlp - 1) }
    }

    func autodetect(force: Bool) { detectIPMIView(force: force); detectIntelJava(force: force) }

    func detectIPMIView(force: Bool) {
        guard force || ipmiview.isEmpty else { return }
        let fm = FileManager.default
        func has(_ p: String) -> Bool { fm.fileExists(atPath: p + "/IPMIView20.jar") }
        // the first place that has one, there the newest (by the version in its name; also one
        // folder down, e.g. ~/Applications/IPMIView/IPMIView_2.25.0_...). Same as the scripts'
        // find_ipmiview (ipmiview-keypasta.sh, container/run.sh).
        for place in Model.ipmiviewPlaces {
            let found = (globFiles(place + "/IPMIView*") + globFiles(place + "/IPMIView*/*")).filter(has)
            if let newest = found.max(by: { Model.versionKey($0) < Model.versionKey($1) }) {
                ipmiview = newest
                return
            }
        }
    }

    static let ipmiviewPlaces = [HOME + "/.local/share", HOME + "/.local/bin", HOME + "/Applications",
                                 "/opt", "/Applications"]

    // A folder's version for sorting: the numbers in its name from its first digit on, each
    // zero-padded ("IPMIView_2.25.0_build.260709" -> "0000000002.0000000025.0000000000.0000260709.")
    static func versionKey(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let digits = name.drop { !("0"..."9").contains($0) }
        return digits.split { !("0"..."9").contains($0) }
            .map { String(repeating: "0", count: max(0, 10 - $0.count)) + $0 + "." }.joined()
    }

    func detectIntelJava(force: Bool) {
        guard force || intelJava.isEmpty else { return }
        let fm = FileManager.default
        let homes = globFiles("/Library/Java/JavaVirtualMachines/*/Contents/Home")
                    .filter { fm.fileExists(atPath: $0 + "/bin/java") }
        // a Java's architecture: OS_ARCH in its release file (x86_64, aarch64); nil if there's none
        func arch(_ home: String) -> String? {
            guard let text = try? String(contentsOfFile: home + "/release", encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n") where line.hasPrefix("OS_ARCH=") {
                return line.dropFirst("OS_ARCH=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\" \r"))
            }
            return nil
        }
        // the viewer's native libraries are Intel only: x86_64 Javas, then those of unknown
        // architecture, never arm64 ones. Among them 11 first, then 8 (newer ones refuse the
        // .jnlp's options; temurin-8.jre, zulu-8.jdk, Oracle's jdk1.8.0_…), then any.
        let intel = homes.filter { ["x86_64", "amd64"].contains(arch($0) ?? "") } + homes.filter { arch($0) == nil }
        let java11 = intel.first { $0.contains("temurin-11") || $0.contains("-11.") }
        let java8 = intel.first { $0.contains("-8.") || $0.contains("jdk1.8") || $0.contains("-1.8") }
        if let pick = java11 ?? java8 ?? intel.first {
            intelJava = pick
        }
    }

    func detectJavaws(force: Bool) {
        guard force || javawsPath.isEmpty else { return }
        if let w = Model.findJavaws() { javawsPath = w }
    }

    // javaws to use for native JNLPs: the configured path, else auto-detected OpenWebStart.
    var resolvedJavaws: String? {
        if !javawsPath.isEmpty, let bin = Model.resolveJavawsBinary(javawsPath) { return bin }
        return Model.findJavaws()
    }

    // Dock names "IPMIView" and "iKVM Viewer" instead of "java" (java-name.sh, java-launcher).
    var launcherPath: String? { Bundle.main.path(forResource: "java-launcher", ofType: nil) }

    // Diagnosis, off: true writes the agent's decisions (never typed keys) to ~/Library/Logs/
    // iKVM-KeyPasta/agent.log, runs IcedTea-Web with -verbose (natively and in a .jnlp container,
    // run.sh --debug) and keeps a .jnlp container's whole output there (jnlp-console-N.log).
    static let debugLogs = false
    static let logDir = NSHomeDirectory() + "/Library/Logs/iKVM-KeyPasta"

    // Agent options for the native launches
    var agentArgs: String {
        var a: [String] = []
        if Model.debugLogs && !Model.logDir.contains(" ") {
            try? FileManager.default.createDirectory(atPath: Model.logDir, withIntermediateDirectories: true)
            a.append("log=" + Model.logDir + "/agent.log")
        }
        return a.joined(separator: ",")
    }


    // the agent jar is bundled inside the app (Resources) and always used.
    var bundledAgent: String? { Bundle.main.path(forResource: "iKVM-KeyPasta-agent", ofType: "jar") }

    // Path handed to Java. JAVA_TOOL_OPTIONS splits on spaces and can't quote them, and the app
    // bundle name contains a space, so a spaced path breaks -javaagent. Stage a copy to a
    // space-free location and use that.
    var effectiveAgent: String {
        guard let src = bundledAgent else { return "" }
        return Model.spaceFree(src)
    }

    // A copy without spaces in its path (in the temp folder), if the path has any; the original if
    // the copy fails. Copied again when it differs.
    static func spaceFree(_ src: String) -> String {
        if !src.contains(" ") { return src }
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "iKVM-KeyPasta"
        let dst = dir + "/" + (src as NSString).lastPathComponent
        if !fm.contentsEqual(atPath: src, andPath: dst) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: dst)
            try? fm.copyItem(atPath: src, toPath: dst)
        }
        return fm.fileExists(atPath: dst) ? dst : src
    }

    // alternate (Option-click): the container's console opens the other way (openConsole)
    func launch(alternate: Bool = false) {
        guard let script = Bundle.main.path(forResource: "ipmiview-keypasta", ofType: "sh") else {
            log = "Bundled ipmiview-keypasta.sh is missing.\n"; return
        }
        if useContainer { runContainer(jnlp: nil, alternate: alternate); return }
        guard !ipmiviewRunning else { log += "IPMIView is already running.\n"; return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script]

        var env = ProcessInfo.processInfo.environment
        if !ipmiview.isEmpty  { env["IPMIVIEW"]   = ipmiview }
        if !effectiveAgent.isEmpty { env["AGENT"] = effectiveAgent; env["AGENT_ARGS"] = agentArgs }
        if let l = launcherPath { env["KEYPASTA_LAUNCHER"] = l }
        if !intelJava.isEmpty { env["INTEL_JAVA"] = intelJava }
        env["IGNORE_EXPIRED_CERT"] = disableTLS ? "true" : "false"
        // A GUI app inherits a bare PATH; stunnel lives in Homebrew.
        env["PATH"] = NSHomeDirectory() + "/.orbstack/bin:/Applications/OrbStack.app/Contents/MacOS/xbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        launching(ipmiview: true)
        run(p, exitLabel: "IPMIView", kind: .ipmiview, onExit: { _ in self.launched(ipmiview: true) })
    }

    // Open a .jnlp (Java Web Start) and run it with the agent.
    func openJnlp() {
        let alternate = NSEvent.modifierFlags.contains(.option)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let jnlpType = UTType(filenameExtension: "jnlp") { panel.allowedContentTypes = [jnlpType] }
        if panel.runModal() == .OK, let url = panel.url { launchJnlp(url.path, alternate: alternate) }
    }

    func launchJnlp(_ path: String, alternate: Bool = false) {
        guard FileManager.default.fileExists(atPath: path) else { log = "JNLP not found: \(path)\n"; return }
        let taken = Model.takeJnlp(path)
        let path = taken.path
        if useContainer { runContainer(jnlp: path, original: taken.original, alternate: alternate); return }
        guard let ws = resolvedJavaws else {
            if Model.dockerAvailable() {
                log = "OpenWebStart not found — opening the JNLP in the container instead.\n"
                runContainer(jnlp: path, original: taken.original, alternate: alternate)
            } else {
                log = "To open a JNLP natively, install OpenWebStart, or turn on \"Run in a container\" (needs Docker).\n"
            }
            return
        }
        // Dedicated OWS profile (separate from the user's own OWS config), configured/re-checked
        // each launch: no proxy, local JVM, no download. We invoke IcedTea-Web's Boot class directly
        // with the bundled JRE, NOT OpenWebStart's own launcher: on macOS OpenWebStartLauncher ignores
        // the JNLP argument and waits for an install4j "open file" Apple event that never arrives when
        // we exec java directly, and PhaseTwoWebStartLauncher strips -Xnofork and always forks a
        // detached stage2 JVM. Boot -Xnofork runs the viewer IN-PROCESS in this JVM, so (a) the JNLP is
        // delivered, (b) our XDG profile and agent apply, and (c) all viewer/ITW output streams into the
        // app's log pane instead of a detached child. Layout from the javaws .app: <root>/openwebstart.jar,
        // <root>/.install4j/i4jruntime.jar, <root>/.install4j/jre.bundle (the bundled JRE).
        let fm = FileManager.default
        Model.writeOWSProfile(searchDir: javaSearchDir)
        let p = Process()
        var env = ProcessInfo.processInfo.environment
        env["XDG_CONFIG_HOME"] = Model.owsProfileConfig
        env["XDG_CACHE_HOME"]  = Model.owsProfileCache
        if !effectiveAgent.isEmpty { env["JAVA_TOOL_OPTIONS"] = "-javaagent:\(effectiveAgent)" + (agentArgs.isEmpty ? "" : "=" + agentArgs) }
        // the agent creates this file once the viewer's window shows (see watchViewerStart)
        let opened = (path as NSString).deletingPathExtension + ".opened"
        try? fm.removeItem(atPath: opened)
        env["KEYPASTA_VIEWER_OPENED"] = opened

        var launched = false
        if let r = ws.range(of: ".app/Contents/") {
            let root = ((String(ws[..<r.lowerBound]) + ".app") as NSString).deletingLastPathComponent
            let javaBin = root + "/.install4j/jre.bundle/Contents/Home/bin/java"
            let owsJar  = root + "/openwebstart.jar"
            let cp      = root + "/.install4j/i4jruntime.jar:" + owsJar
            if fm.isExecutableFile(atPath: javaBin), fm.fileExists(atPath: owsJar) {
                let javaArgs = ["-cp", cp, "net.sourceforge.jnlp.runtime.Boot", "-Xnofork"]
                    + (Model.debugLogs ? ["-verbose"] : []) + [path]
                if let namer = Bundle.main.path(forResource: "java-name", ofType: "sh"), let l = launcherPath {
                    // as "iKVM Viewer" in the Dock (see java-name.sh)
                    env["KEYPASTA_JAVA_HOME"] = root + "/.install4j/jre.bundle/Contents/Home"
                    env["KEYPASTA_LAUNCHER"] = l
                    p.executableURL = URL(fileURLWithPath: "/bin/bash")
                    p.arguments = [namer] + javaArgs
                } else {
                    p.executableURL = URL(fileURLWithPath: javaBin)
                    p.arguments = javaArgs
                }
                launched = true
            }
        }
        if !launched {
            // A real command-line javaws, or an unexpected layout: run the resolved binary directly.
            p.executableURL = URL(fileURLWithPath: ws)
            p.arguments = [path]
        }
        p.environment = env
        launching(ipmiview: false)
        var ended = false
        run(p, exitLabel: "JNLP " + (path as NSString).lastPathComponent, kind: .jnlp, onExit: { _ in
            if !ended { ended = true; if self.launchingJnlp > 0 { self.launched(ipmiview: false) } }
        })
        // the viewer's window opened: the agent's file. Run by Boot -Xnofork, the viewer is this
        // process (java-name.sh execs): its end without the file is the end of the wait. A plain
        // javaws (launched false) may hand the viewer on and end: only the time counts then.
        let viaBoot = launched
        watchViewerStart(taken.original) {
            if fm.fileExists(atPath: opened) { try? fm.removeItem(atPath: opened); return .started }
            return viaBoot && !p.isRunning ? .gone : .notYet
        }
    }

    // The .jnlp where the browser saved it (takeJnlp) is deleted only once a viewer window has
    // opened from its copy (state: the agent created the file KEYPASTA_VIEWER_OPENED names when the
    // viewer's window showed, which it builds after connecting and logging in), if it's still the
    // same file (the browser then saves the next one under the same name). Any other outcome (no
    // window within viewerWait seconds, no agent) leaves it there for another try.
    enum ViewerState { case notYet, started, gone }
    static let viewerWait = 300.0
    func watchViewerStart(_ original: (path: String, data: Data)?, state: @escaping () -> ViewerState) {
        guard let original else { return }
        let name = (original.path as NSString).lastPathComponent
        DispatchQueue.global(qos: .utility).async {
            let end = Date().addingTimeInterval(Model.viewerWait)
            var s = ViewerState.notYet
            while Date() < end {
                s = state()
                if s != .notYet { break }
                Thread.sleep(forTimeInterval: 1)
            }
            let result = s
            DispatchQueue.main.async {
                let fm = FileManager.default
                if result == .started {
                    if fm.contents(atPath: original.path) == original.data, (try? fm.removeItem(atPath: original.path)) != nil {
                        self.log += "Viewer window opened: \(name) removed from where it was saved.\n"
                    }
                } else if fm.fileExists(atPath: original.path) {
                    self.log += "No viewer window opened from \(name): kept where it was saved, for another try.\n"
                }
            }
        }
    }

    // A program's exit status and output (stdout and stderr), waited for
    static func output(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        return output(p)
    }

    static func output(_ p: Process) -> (Int32, String) {
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // Directory to point OWS at for finding local JVMs (the folder holding the viewer Java), or the
    // standard location.
    var javaSearchDir: String {
        if let r = intelJava.range(of: "/Contents/Home") {
            let dir = (String(intelJava[..<r.lowerBound]) as NSString).deletingLastPathComponent
            if !dir.isEmpty { return dir }
        }
        return "/Library/Java/JavaVirtualMachines"
    }

    static let consolePort = 6100

    // A console's addresses, for the main window's tooltip
    static func addresses(_ port: Int) -> String {
        "Browser: localhost:" + String(port) + " · VNC: localhost:" + String(port - 400)
    }

    // A console's address (noVNC), plain: connecting at once, the desktop following the window
    // and the paste hotkey are set in the container (Dockerfile, entrypoint.sh). noVNC doesn't
    // reconnect by default (a viewer's tab: its desktop is gone with the viewer).
    func consoleURL(_ port: Int, tab: Bool = false) -> String {
        "http://localhost:\(port)/"
    }

    // Build (first run) and start the container in the background, streaming output into the log.
    // No Terminal: the app runs it and opens the console (openConsole) once it is up.
    func runContainer(jnlp: String?, original: (path: String, data: Data)? = nil, alternate: Bool = false) {
        guard !containerBusy else { return }
        if passwordNeeded && vncPassword.isEmpty {
            log = "The consoles need a password (Preferences › Container › Security): not started.\n"
            return
        }
        guard let script = Bundle.main.path(forResource: "run", ofType: "sh", inDirectory: "container") else {
            log = "container/run.sh is missing from the app bundle (rebuild with build.sh).\n"; return
        }
        // invoke via bash so a missing +x bit on the bundled script can never block the launch
        // IPMIView's container on 6100; a .jnlp's its own, on a port run.sh picks (6201-6299)
        var parts = ["bash", Model.shq(script), "--detach"]
        if jnlp == nil             { parts += ["--port", "\(Model.consolePort)"] }
        if !ipmiview.isEmpty       { parts += ["--ipmiview", Model.shq(ipmiview)] }
        if !effectiveAgent.isEmpty { parts += ["--agent", Model.shq(effectiveAgent)] }
        if disableTLS              { parts += ["--relax"] }
        let layout = effectiveContainerLayout
        parts += ["--layout", Model.shq(layout)]
        if viewerTabs              { parts += ["--viewer-tabs"] }
        if !isoDir.isEmpty         { parts += ["--vmedia-dir", Model.shq(isoDir)] }
        if !screencapDir.isEmpty   { parts += ["--screencap-dir", Model.shq(screencapDir)] }
        if let j = jnlp            { parts += ["--jnlp", Model.shq(j)] }
        if !localOnly              { parts += ["--lan"] }
        if Model.debugLogs         { parts += ["--debug"] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", parts.joined(separator: " ")]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = NSHomeDirectory() + "/.orbstack/bin:/Applications/OrbStack.app/Contents/MacOS/xbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        // the password in run.sh's environment only (docker -e VNC_PASSWORD takes it from there):
        // on no command line, in no log
        env["VNC_PASSWORD"] = passwordNeeded ? vncPassword : nil
        p.environment = env
        let note = "Keyboard layout in the container: \(layout) ("
            + (containerLayoutChoice == "auto" ? "from the Mac's input source" : "Preferences › Container") + ")\n"
        let isIPMIView = jnlp == nil
        busyWithIPMIView = isIPMIView
        launching(ipmiview: isIPMIView)
        run(p, exitLabel: jnlp == nil ? "container start" : ".jnlp container start", kind: .container, onSuccess: { output in
            if jnlp == nil {
                self.containerRunning = true
                self.waitThenOpenConsole(Model.consolePort, alternate: alternate) { self.launched(ipmiview: true) }
                if self.viewerTabs { self.watchViewerTabs() }
                self.watchContainers()
                self.log += note
            } else if let port = Model.startedPort(in: output) {
                self.log += note
                if !self.jnlpConsoles.contains(port) { self.jnlpConsoles.append(port) }
                self.waitThenOpenConsole(port, alternate: alternate) { self.launched(ipmiview: false) }
                self.watchContainers()
                // the viewer's window opened in its container (ikvm-jnlp-PORT, gone with the
                // viewer): the agent's file there (entrypoint.sh sets KEYPASTA_VIEWER_OPENED)
                self.watchViewerStart(original) {
                    let (_, out) = Model.output(Model.docker("exec ikvm-jnlp-\(port) sh -c "
                        + Model.shq("test -e /tmp/viewer-opened && echo opened || echo waiting")))
                    if out.contains("opened") { return .started }
                    return out.contains("waiting") ? .notYet : .gone
                }
            } else {
                self.launched(ipmiview: false)
            }
        }, onExit: { status in
            if status != 0 { self.launched(ipmiview: isIPMIView) }
        })
    }

    // The container's X keyboard layout: the Mac's current one. The container takes each key by
    // its place (Xvnc RawKeyboard), so the layout decides the characters typed in IPMIView there,
    // as on the Mac (the remote's are its own: the agent sends places). The PC variant of the Mac
    // layout (Option is Alt; AltGr: the right Option); unknown: US.
    // The layouts Preferences offers for the containers (xkb name, shown name)
    static let containerLayouts: [(String, String)] = [
        ("ch", "Swiss German"), ("ch(fr)", "Swiss French"), ("de", "German"), ("at", "Austrian"),
        ("us", "US"), ("us(intl)", "US International"), ("gb", "British"), ("ie", "Irish"),
        ("fr", "French"), ("be", "Belgian"), ("ca", "Canadian French"), ("it", "Italian"),
        ("es", "Spanish"), ("pt", "Portuguese"), ("br", "Brazilian"), ("nl", "Dutch"),
        ("dk", "Danish"), ("no", "Norwegian"), ("se", "Swedish"), ("fi", "Finnish"),
        ("pl", "Polish"), ("cz", "Czech"), ("sk", "Slovak"), ("hu", "Hungarian")]

    static func layoutName(_ xkb: String) -> String {
        containerLayouts.first { $0.0 == xkb }?.1 ?? xkb
    }

    // From the Mac's input source: its ID's last part (com.apple.keylayout.SwissGerman ->
    // SwissGerman -> ch); a layout of one's own (org.unknown.keylayout.<name>) says nothing: us,
    // and Preferences › Container picks it then.
    static var containerLayout: String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "us" }
        let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        let name = (id.components(separatedBy: ".").last ?? "").lowercased().filter { $0.isLetter }
        let layouts: [(String, String)] = [
            ("swissgerman", "ch"), ("swissfrench", "ch(fr)"), ("austrian", "at"), ("german", "de"),
            ("british", "gb"), ("irish", "ie"), ("canadianfrench", "ca"), ("french", "fr"), ("belgian", "be"),
            ("italian", "it"), ("spanish", "es"), ("portuguese", "pt"), ("brazilian", "br"),
            ("danish", "dk"), ("norwegian", "no"), ("swedish", "se"), ("finnish", "fi"),
            ("polish", "pl"), ("czech", "cz"), ("slovak", "sk"), ("hungarian", "hu"),
            ("usinternational", "us(intl)"), ("us", "us"), ("abc", "us"), ("dutch", "us")]
        for (prefix, layout) in layouts where name.hasPrefix(prefix) { return layout }
        return "us"
    }

    // An iKVM .jnlp (tw.com.aten.ikvm) is copied from where the browser saved it to
    // ~/Library/Caches/iKVM-KeyPasta/launch-<date>-<time>-<BMC>-<random>.jnlp, readable by you only
    // (it holds the console session's login data), and kept there for a week after it was last
    // opened (older ones are deleted here), as on Windows and Linux. The original (with its content)
    // is returned too: deleted once a viewer has started from the copy (watchViewerStart), so the
    // browser gives the next one the same name. Other .jnlp files, one already there, or a failed
    // copy: used where they are (no original).
    static func takeJnlp(_ path: String) -> (path: String, original: (path: String, data: Data)?) {
        let fm = FileManager.default
        let dir = NSHomeDirectory() + "/Library/Caches/iKVM-KeyPasta"
        guard let data = fm.contents(atPath: path) else { return (path, nil) }
        let text = String(decoding: data, as: UTF8.self)
        guard text.range(of: "tw.com.aten.ikvm", options: .caseInsensitive) != nil else { return (path, nil) }
        // copies not opened for a week: deleted; this one counts as opened now
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                where name.hasPrefix("launch-") && name.hasSuffix(".jnlp") {
            let f = dir + "/" + name
            if f != path, let d = (try? fm.attributesOfItem(atPath: f))?[.modificationDate] as? Date, d < weekAgo {
                try? fm.removeItem(atPath: f)
            }
        }
        if (path as NSString).deletingLastPathComponent == dir {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
            return (path, nil)
        }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch { return (path, nil) }
        // the BMC: the address the browser used, from the codebase; port off, others as _
        var bmc = "unknown"
        if let re = try? NSRegularExpression(pattern: #"codebase\s*=\s*["'][a-z]+://([^/"']+)"#,
                                             options: .caseInsensitive),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text) {
            var host = String(text[r])
            if let port = host.range(of: #":[0-9]+$"#, options: .regularExpression) { host.removeSubrange(port) }
            host = String(host.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "_" })
            if !host.isEmpty { bmc = host }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dst = dir + "/launch-" + f.string(from: Date()) + "-" + bmc + "-"
            + String(format: "%06ld", Int.random(in: 0..<1_000_000)) + ".jnlp"
        guard fm.createFile(atPath: dst, contents: data, attributes: [.posixPermissions: 0o600]) else { return (path, nil) }
        return (dst, (path, data))
    }

    // launch.jnlp, launch (1).jnlp, launch-2.jnlp, launcher.jnlp ...: the newest (modified last)
    static func newestLaunchJnlp(in dir: String) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let candidates = names.filter { $0.lowercased().hasPrefix("launch") && $0.lowercased().hasSuffix(".jnlp") }
            .map { dir + "/" + $0 }
        func date(_ p: String) -> Date { (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast }
        return candidates.max { date($0) < date($1) }
    }

    // The newest launch*.jnlp in Downloads, for the window's "Open Downloads/…" button. Kept
    // current by a watch on the folder: a browser saves under a temporary name (or in a .download
    // folder) and renames or moves the file, each a change of the folder's entries (writing into a
    // file isn't). Looked at 0.3 s after the first change, so a burst of them is one look. Also
    // whenever the app comes to the front, which starts the watch again if the folder couldn't be
    // opened before (macOS asking for access to Downloads).
    static let downloadsDir = NSHomeDirectory() + "/Downloads"
    @Published var downloadsJnlp: String?
    private var downloadsWatch: DispatchSourceFileSystemObject?
    private var downloadsLookPending = false
    private var activeObserver: NSObjectProtocol?

    func watchDownloads() {
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.watchDownloads()
            }
        }
        lookInDownloads()
        guard downloadsWatch == nil else { return }
        let fd = open(Model.downloadsDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, !self.downloadsLookPending else { return }
            self.downloadsLookPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.downloadsLookPending = false
                self?.lookInDownloads()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        downloadsWatch = src
    }

    private func lookInDownloads() {
        let newest = Model.newestLaunchJnlp(in: Model.downloadsDir)
        if newest != downloadsJnlp { downloadsJnlp = newest }
    }

    // run.sh's "console-port: N"
    static func startedPort(in output: String) -> Int? {
        for line in output.split(separator: "\n") where line.hasPrefix("console-port: ") {
            return Int(line.dropFirst("console-port: ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // Poll the console's web port until its noVNC page answers (Docker accepts connections on a
    // published port before anything listens behind it), then open the console (openConsole).
    func waitThenOpenConsole(_ port: Int, alternate: Bool = false, done: (() -> Void)? = nil) {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/bash")
        probe.arguments = ["-c", "for _ in $(seq 1 90); do curl -fsS -m 2 \"http://localhost:\(port)/vnc.html\" >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"]
        probe.terminationHandler = { proc in
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    self.log += "Console is up — opening it.\n"
                    self.openConsole(port, tips: port == Model.consolePort, alternate: alternate)
                } else {
                    self.log += "The console didn't come up yet. When it does, click Open console.\n"
                }
                done?()
            }
        }
        try? probe.run()
    }

    // Viewer tabs: each viewer the container starts gets a desktop of its own, served on the next
    // free port of 6101-6199 (container/entrypoint.sh). Polled every 2 s while the container runs:
    // a port whose noVNC page answers and didn't before is a new viewer: opened in a new tab. A new
    // viewer takes the lowest free number, so up to 3 above the highest one up is enough to ask
    // (not 99 curls every 2 s; 3: viewers started together within one poll). Docker
    // accepts connections on published ports even with nothing behind them, so the page itself is
    // asked for, not just the port; with curl, as waitThenOpenConsole does.
    private var tabTimer: Timer?
    private var tabsUp = Set<Int>()
    private var tabProbe: Process?

    // openRunning false (a container found running at the app's start): the viewers already up
    // get no new tab (theirs is likely still open), only those that come up afterwards.
    private var seedTabs = false

    func watchViewerTabs(openRunning: Bool = true) {
        tabTimer?.invalidate()
        tabsUp.removeAll()
        seedTabs = !openRunning
        log += "iKVM Viewers open in browser tabs of their own (ports 6101-6199).\n"
        tabTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.containerRunning else { self.tabTimer?.invalidate(); self.tabTimer = nil; return }
            if let running = self.tabProbe, running.isRunning { return }
            let top = min(6199, (self.tabsUp.max() ?? 6100) + 3)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "for p in $(seq 6101 \(top)); do ( curl -fsS -m 1.5 -o /dev/null \"http://localhost:$p/vnc.html\" 2>/dev/null && echo $p ) & done; wait"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let up = Set(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { Int($0) })
                DispatchQueue.main.async { self.viewerTabsUp(up) }
            }
            self.tabProbe = p
            try? p.run()
        }
    }

    private func viewerTabsUp(_ up: Set<Int>) {
        if seedTabs {
            seedTabs = false
            tabsUp = up
            viewerTabPorts = up.sorted()
            fetchViewerNames()
            return
        }
        for port in up.subtracting(tabsUp).sorted() {
            log += "iKVM Viewer in a new tab (port \(port)).\n"
            openConsole(port, tab: true, via: viewersViaVNC)
        }
        if up != tabsUp { fetchViewerNames() }
        tabsUp = up
        viewerTabPorts = up.sorted()
        stoppingViewers.formIntersection(up)
    }

    // The viewers' BMCs, as the container's viewer-tab script wrote them (/tmp/viewer-names/N)
    private func fetchViewerNames() {
        let p = Model.docker("exec ikvm-console grep -r . /tmp/viewer-names")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            var names: [Int: String] = [:]
            for line in text.split(separator: "\n") {     // /tmp/viewer-names/3:obelix-ipmi
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let n = Int(parts[0].split(separator: "/").last ?? "") else { continue }
                names[6100 + n] = String(parts[1])
            }
            DispatchQueue.main.async { self.viewerNames = names }
        }
        try? p.run()
    }

    // A viewer's own desktop menu's "End this console": that viewer only, IPMIView stays
    func stopViewer(_ port: Int) {
        stoppingViewers.insert(port)
        try? Model.docker("exec ikvm-console /tmp/viewer-end\(port - 6100)").run()
        log += "The iKVM Viewer on port \(port) is ending.\n"
    }

    // The containers can end without the app: a .jnlp one with its viewer (run.sh starts them to
    // be removed), IPMIView's by hand or with the engine. Every 5 s, while there are any, which
    // still run.
    private var jnlpTimer: Timer?

    func watchContainers() {
        guard jnlpTimer == nil else { return }
        jnlpTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.jnlpConsoles.isEmpty && !self.containerRunning { self.jnlpTimer?.invalidate(); self.jnlpTimer = nil; return }
            let p = Model.docker("ps --format '{{.Names}}'")
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else { return }       // docker not answering: keep them
                let names = Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
                DispatchQueue.main.async {
                    for port in self.jnlpConsoles where !names.contains("ikvm-jnlp-\(port)") {
                        self.log += "The .jnlp console \(port - 6200) (port \(port)) ended.\n"
                        self.jnlpEnded(port)
                    }
                    self.jnlpConsoles.removeAll { !names.contains("ikvm-jnlp-\($0)") }
                    if self.containerRunning && !names.contains("ikvm-console") {
                        self.containerRunning = false
                        self.log += "The IPMIView container ended.\n"
                    }
                }
            }
            try? p.run()
        }
    }

    // At the app's start: containers of ours already running (IPMIView's restarts with the engine;
    // the app may have quit while they ran). Listed, watched; IPMIView's viewer tabs too, without
    // reopening those already up. Nothing started: an engine that isn't running just answers no.
    func detectRunningContainers() {
        guard Model.dockerAvailable() else { return }
        let p = Model.docker("ps --format '{{.Names}}'")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            guard proc.terminationStatus == 0 else { return }
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            let ports = names.compactMap { n -> Int? in
                guard n.hasPrefix("ikvm-jnlp-"), let port = Int(n.dropFirst("ikvm-jnlp-".count)),
                      (6201...6299).contains(port) else { return nil }
                return port
            }.sorted()
            DispatchQueue.main.async {
                var found: [String] = []
                if names.contains("ikvm-console") && !self.containerRunning {
                    self.containerRunning = true
                    found.append("IPMIView")
                    if self.viewerTabs { self.watchViewerTabs(openRunning: false) }
                }
                for port in ports where !self.jnlpConsoles.contains(port) {
                    self.jnlpConsoles.append(port)
                    found.append(".jnlp (port \(port))")
                }
                if found.isEmpty { return }
                self.log += "Already running: " + found.joined(separator: ", ") + ".\n"
                self.watchContainers()
            }
        }
        try? p.run()
    }

    // A .jnlp container that ended (it isn't removed by itself, run.sh: no --rm): the last 40 lines
    // of its output (IcedTea-Web's and the viewer's, e.g. why a start failed) into the log, all of
    // it to ~/Library/Logs/iKVM-KeyPasta with debugLogs; then removed.
    func jnlpEnded(_ port: Int) {
        let p = Model.docker("logs ikvm-jnlp-\(port) 2>&1; " + "true")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.terminationHandler = { _ in
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                if !text.isEmpty {
                    let file = Model.logDir + "/jnlp-console-\(port - 6200).log"
                    var saved = false
                    if Model.debugLogs {
                        try? FileManager.default.createDirectory(atPath: Model.logDir, withIntermediateDirectories: true)
                        saved = (try? text.write(toFile: file, atomically: true, encoding: .utf8)) != nil
                    }
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    self.log += "— its last output" + (saved ? " (all of it: " + file + ")" : "") + " —\n"
                        + lines.suffix(40).joined(separator: "\n") + (text.hasSuffix("\n") ? "" : "\n")
                }
                try? Model.docker("rm -f ikvm-jnlp-\(port)").run()
            }
        }
        try? p.run()
    }

    func stopJnlp(_ port: Int) {
        try? Model.docker("rm -f ikvm-jnlp-\(port)").run()
        jnlpConsoles.removeAll { $0 == port }
        log += "The .jnlp console on port \(port) stopped.\n"
    }

    // The container command, as run.sh picks it: docker (Docker Desktop, OrbStack, Colima), else
    // podman (it takes docker's commands)
    static let containerCLIs = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                                "/Applications/Docker.app/Contents/Resources/bin/docker",
                                NSHomeDirectory() + "/.orbstack/bin/docker",
                                "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
                                "/opt/podman/bin/podman", "/opt/homebrew/bin/podman", "/usr/local/bin/podman"]

    // docker (or podman) with the given arguments (a shell line)
    static func docker(_ args: String) -> Process {
        let docker = containerCLIs.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "docker"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "\(Model.shq(docker)) \(args)"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = NSHomeDirectory() + "/.orbstack/bin:/Applications/OrbStack.app/Contents/MacOS/xbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        return p
    }

    func openBrowserConsole(alternate: Bool = false) {
        openConsole(Model.consolePort, tips: true, alternate: alternate)
    }

    // A container's console (web port: 6100, 6101-6199, 6201-6299) in a VNC app goes to the same
    // desktop's VNC port (web port - 400, run.sh): no browser between the keys and the container.
    // The VNC app the consoles open in (vncChoice), nil: the browser
    enum VNCTarget { case tiger(String), app(String), command(String) }

    var vncTarget: VNCTarget? {
        switch vncChoice {
        case "none":
            return nil
        case "tiger":
            return Model.tigerVNCApp.map { VNCTarget.tiger($0) }
        case "command":
            let cmd = vncCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return cmd.isEmpty ? nil : .command(cmd)
        default:
            if vncChoice.hasPrefix("app:") {
                let app = String(vncChoice.dropFirst(4))
                return FileManager.default.fileExists(atPath: app) ? .app(app) : nil
            }
            return Model.tigerVNCApp.map { VNCTarget.tiger($0) }        // "auto"
        }
    }

    // The Open console button's other way (Option-click): its label
    var alternateOpenLabel: String { vncTarget == nil ? "Open in VNC app" : "Open in Browser" }
    var alternateWhere: String { vncTarget == nil ? "in the VNC app" : "in the browser" }

    // A console: in the VNC app if there is one, else the browser; alternate (Option-click): the
    // other one (the VNC app then: TigerVNC Viewer).
    // via: this way, whatever is set (IPMIView's viewers: as its console was opened last).
    // IPMIView's console: how it was opened is remembered (ipmiviewViaVNC).
    func openConsole(_ port: Int, tab: Bool = false, tips: Bool = false, alternate: Bool = false, via: Bool? = nil) {
        let target = vncTarget
        let viaVNC = via.map { $0 != alternate } ?? ((target != nil) != alternate)
        if port == Model.consolePort { ipmiviewViaVNC = viaVNC }
        if target == nil && viaVNC == false && via == nil {
            switch vncChoice {
            case "tiger": log += "TigerVNC Viewer isn't installed (brew install --cask tigervnc-viewer): opened in the browser.\n"
            case "command": log += "No VNC command set in Preferences: opened in the browser.\n"
            case let c where c.hasPrefix("app:"): log += "The VNC app chosen in Preferences is gone: opened in the browser.\n"
            default: break
            }
        }
        if viaVNC {
            // the alternate way to a VNC app with none chosen: TigerVNC Viewer (macOS's Screen
            // Sharing never got past "connecting" with these desktops: not offered)
            guard let t = target ?? Model.tigerVNCApp.map({ VNCTarget.tiger($0) }) else {
                log += "No VNC app: install TigerVNC Viewer (brew install --cask tigervnc-viewer) or choose one in Preferences › Container.\n"
                return
            }
            openInVNC(port, t)
        } else {
            openBrowser(consoleURL(port, tab: tab), tips: tips)
        }
    }

    func openInVNC(_ port: Int, _ target: VNCTarget) {
        let vnc = port - 400
        let o = Process(); o.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        switch target {
        case .tiger(let app):
            openVNC(app, vnc)
            return
        case .app(let app):
            o.arguments = ["-a", app, "vnc://127.0.0.1:" + String(vnc)]
        case .command(let cmd):
            runConsoleCommand(cmd, vars: ["HOST": "127.0.0.1", "VNCPORT": String(vnc)],
                              missing: " \"vnc://${HOST}:${VNCPORT}\"", what: "VNC")
            return
        }
        try? o.run()
    }

    // TigerVNC Viewer (Homebrew's cask names it with its version)
    static var tigerVNCApp: String? {
        (globFiles("/Applications/TigerVNC*.app") + globFiles(NSHomeDirectory() + "/Applications/TigerVNC*.app")).sorted().last
    }

    func openVNC(_ app: String, _ port: Int) {
        let o = Process(); o.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        o.arguments = ["-na", app, "--args", "127.0.0.1::\(port)"]
        try? o.run()
    }

    // The browser chosen in Preferences (browserChoice "app:" or "default"); else (also for "auto"
    // and the fallbacks) a Chromium browser if there is one (fullscreen there captures
    // Ctrl+Tab/Alt+Tab for the remote), else the default browser.
    func openBrowser(_ url: String, tips: Bool = false) {
        let fm = FileManager.default
        if browserChoice == "command" {
            let cmd = browserCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty {
                runConsoleCommand(cmd, vars: ["URL": url], missing: " \"${URL}\"", what: "browser")
                return
            }
            log += "No browser command set in Preferences: opened as \"Automatic\".\n"
        } else if browserChoice.hasPrefix("app:") {
            let app = String(browserChoice.dropFirst(4))
            if fm.fileExists(atPath: app) {
                let o = Process(); o.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                o.arguments = ["-a", app, url]; try? o.run()
                if tips && Model.isChromium(app) {
                    log += "Tip: click noVNC's fullscreen button — that captures Ctrl+Tab/Alt+Tab and sends them to the remote.\n"
                }
                return
            }
            log += "The browser chosen in Preferences is gone (\(app)): opened as \"Automatic\".\n"
        } else if browserChoice == "default" {
            Model.openURL(url)
            return
        }
        let chromium = ["Google Chrome", "Microsoft Edge", "Chromium", "Brave Browser", "Vivaldi"]
        for app in chromium where fm.fileExists(atPath: "/Applications/\(app).app") {
            let o = Process(); o.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            o.arguments = ["-a", app, url]; try? o.run()
            if !tips { return }
            self.log += "Tip: click noVNC's fullscreen button — in \(app) that captures Ctrl+Tab/Alt+Tab and sends them to the remote.\n"
            return
        }
        Model.openURL(url)   // default browser; if it is Safari, full-key capture is unavailable
        if tips { self.log += "Opened in your default browser. For Ctrl+Tab/Alt+Tab to reach the remote, use Chrome or Edge in fullscreen.\n" }
    }

    // The user's console command (browser: URL; VNC app: HOST, VNCPORT), by /bin/sh, with the
    // variables in its environment (the shell puts them in, quoted as written); with none of them
    // in it, `missing` is appended. Its error output (the first 2000 characters) goes to the log if
    // it fails.
    func runConsoleCommand(_ cmd: String, vars: [String: String], missing: String, what: String) {
        let used = vars.keys.contains { cmd.contains("$" + $0) || cmd.contains("${" + $0 + "}") }
        let line = used ? cmd : cmd + missing
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", line]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in vars { env[k] = v }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        let lock = NSLock()
        var errText = ""
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            lock.lock(); if errText.count < 2000 { errText += String(decoding: d, as: UTF8.self) }; lock.unlock()
        }
        p.terminationHandler = { proc in
            err.fileHandleForReading.readabilityHandler = nil
            lock.lock(); let text = String(errText.prefix(2000)); lock.unlock()
            if proc.terminationStatus != 0 {
                DispatchQueue.main.async {
                    self.log += "The " + what + " command failed (status \(proc.terminationStatus))"
                        + (text.isEmpty ? "" : ": " + text) + "\n"
                }
            }
        }
        do { try p.run() } catch { log += "The " + what + " command couldn't start: \(error.localizedDescription)\n" }
    }

    static let browserCommandExample = "open -na \"Google Chrome\" --args --profile-directory=\"Profile 1\" --app=\"${URL}\""
    static let vncCommandExample = "open -na \"TigerVNC Viewer\" --args -FullScreen \"${HOST}::${VNCPORT}\""

    static func isChromium(_ app: String) -> Bool {
        ["Chrome", "Edge", "Chromium", "Brave", "Vivaldi", "Opera", "Arc"].contains { app.contains($0) }
    }

    // Browsers for Preferences: those macOS knows for http, the ones chosen with "Other…", and the
    // chosen one; one per name, by name.
    var browserApps: [String] {
        var apps: [String] = []
        if #available(macOS 12.0, *), let u = URL(string: "http://localhost") {
            apps = NSWorkspace.shared.urlsForApplications(toOpen: u).map { $0.path }
        } else {
            apps = ["Safari", "Google Chrome", "Microsoft Edge", "Firefox", "Chromium", "Brave Browser", "Vivaldi", "Arc", "Opera"]
                .map { "/Applications/\($0).app" }.filter { FileManager.default.fileExists(atPath: $0) }
        }
        apps += customBrowsers
        if browserChoice.hasPrefix("app:") { apps.append(String(browserChoice.dropFirst(4))) }
        var seen = Set<String>()
        var unique: [String] = []
        for a in apps where !seen.contains(Model.appName(a)) {
            seen.insert(Model.appName(a))
            unique.append(a)
        }
        // the chosen one keeps its place even if another copy of the same name came first
        if browserChoice.hasPrefix("app:") {
            let chosen = String(browserChoice.dropFirst(4))
            if let i = unique.firstIndex(where: { Model.appName($0) == Model.appName(chosen) }) { unique[i] = chosen }
        }
        return unique.sorted { Model.appName($0).localizedCaseInsensitiveCompare(Model.appName($1)) == .orderedAscending }
    }

    static func appName(_ path: String) -> String {
        (FileManager.default.displayName(atPath: path) as NSString).deletingPathExtension
    }

    var defaultBrowserName: String? {
        if #available(macOS 12.0, *), let u = URL(string: "http://localhost"),
           let app = NSWorkspace.shared.urlForApplication(toOpen: u) {
            return Model.appName(app.path)
        }
        return nil
    }

    // VNC apps for Preferences: the ones chosen with "Select other…", and the chosen one
    var vncApps: [String] {
        var apps = customVNCApps
        if vncChoice.hasPrefix("app:") { apps.append(String(vncChoice.dropFirst(4))) }
        var seen = Set<String>()
        return apps.filter { seen.insert($0).inserted }
            .sorted { Model.appName($0).localizedCaseInsensitiveCompare(Model.appName($1)) == .orderedAscending }
    }

    private func vncChoiceChanged(_ old: String) {
        if vncChoice == "other" {
            DispatchQueue.main.async {
                if let app = Model.chooseApp("Choose the VNC app the consoles open in (with a vnc:// address)") {
                    if !self.customVNCApps.contains(app) { self.customVNCApps.append(app) }
                    self.vncChoice = "app:" + app
                } else {
                    self.vncChoice = old
                }
            }
            return
        }
        UserDefaults.standard.set(vncChoice, forKey: "vncChoice")
    }

    static func chooseApp(_ message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.message = message
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    // The desktops' password: a file readable by this user only (not the Keychain: the app is
    // signed ad hoc, a new build would be asked for it every time)
    static var passwordFile: String { NSHomeDirectory() + "/Library/Application Support/iKVM-KeyPasta/vnc-password" }

    static func loadPassword() -> String {
        (try? String(contentsOfFile: passwordFile, encoding: .utf8)) ?? ""
    }

    static func savePassword(_ pw: String) {
        let fm = FileManager.default
        if pw.isEmpty { try? fm.removeItem(atPath: passwordFile); return }
        try? fm.createDirectory(atPath: (passwordFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: passwordFile) {
            fm.createFile(atPath: passwordFile, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordFile)
        try? pw.write(toFile: passwordFile, atomically: false, encoding: .utf8)
    }

    // "Other…" in Preferences: an app chosen in an open dialog; cancelled: the choice before.
    private func browserChoiceChanged(_ old: String) {
        if browserChoice == "other" {
            DispatchQueue.main.async { self.chooseOtherBrowser(previous: old) }
            return
        }
        UserDefaults.standard.set(browserChoice, forKey: "browserChoice")
    }

    func chooseOtherBrowser(previous: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.message = "Choose the browser the consoles open in"
        if panel.runModal() == .OK, let url = panel.url {
            if !customBrowsers.contains(url.path) { customBrowsers.append(url.path) }
            browserChoice = "app:" + url.path
        } else {
            browserChoice = previous
        }
    }

    func stopContainer() {
        try? Model.docker("rm -f ikvm-console").run()
        containerRunning = false
        log += "Container stopped.\n"
    }

    // A .jnlp dropped on the window.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let alternate = NSEvent.modifierFlags.contains(.option)
        for pr in providers {
            _ = pr.loadObject(ofClass: URL.self) { url, _ in
                if let u = url, u.pathExtension.lowercased() == "jnlp" {
                    DispatchQueue.main.async { self.launchJnlp(u.path, alternate: alternate) }
                }
            }
        }
        return true
    }

    // A .jnlp passed on the command line (e.g. opened via the Finder "open" command).
    func handleLaunchArgs() {
        if let j = CommandLine.arguments.dropFirst().first(where: {
            $0.lowercased().hasSuffix(".jnlp") && FileManager.default.fileExists(atPath: $0) }) {
            launchJnlp(j)
        }
    }

    private func setRunning(_ kind: RunKind, _ on: Bool) {
        switch kind {
        case .ipmiview: ipmiviewRunning = on
        case .jnlp: jnlpRunning = max(0, jnlpRunning + (on ? 1 : -1))
        case .container: containerBusy = on
        }
    }

    // onSuccess gets the process's output (also in the log)
    private func run(_ p: Process, exitLabel: String, kind: RunKind, onSuccess: ((String) -> Void)? = nil,
                     onExit: ((Int32) -> Void)? = nil) {
        if anyRunning { log += "\n— \(exitLabel) —\n" } else { log = "" }   // others' output stays
        setRunning(kind, true)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = pipe
        let lock = NSLock()
        var output = ""
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            lock.lock(); output += s; lock.unlock()
            DispatchQueue.main.async { self.log += s }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            // what's left unread (run.sh's last line: the console's port). Not for IPMIView and the
            // viewers: what they started (stunnel) may keep the pipe open, reading would wait for it
            let rest = kind == .container
                ? String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) : ""
            lock.lock(); output += rest; let all = output; lock.unlock()
            DispatchQueue.main.async {
                if !rest.isEmpty { self.log += rest }
                self.setRunning(kind, false)
                self.log += "\n— \(exitLabel) exited (status \(proc.terminationStatus)) —\n"
                if proc.terminationStatus == 0 { onSuccess?(all) }
                onExit?(proc.terminationStatus)
            }
        }
        do { try p.run() }
        catch { log += "Failed to start: \(error.localizedDescription)\n"; setRunning(kind, false); onExit?(-1) }
    }

    static func openURL(_ s: String) {
        let o = Process(); o.executableURL = URL(fileURLWithPath: "/usr/bin/open"); o.arguments = [s]
        try? o.run()
    }

    static func openPreferences() {
        if #available(macOS 13, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    // A dedicated OWS config/cache profile for the launcher (separate from the user's own OWS).
    static var owsProfileConfig: String { NSHomeDirectory() + "/Library/Application Support/iKVM-KeyPasta/ows" }
    static var owsProfileCache:  String { NSHomeDirectory() + "/Library/Application Support/iKVM-KeyPasta/ows-cache" }

    // Write/merge the required values into the dedicated profile's deployment.properties (keeping
    // anything OWS itself added). Done on every launch so the profile is always correct.
    static func writeOWSProfile(searchDir: String) {
        let dir = owsProfileConfig + "/icedtea-web"
        let cfg = dir + "/deployment.properties"
        let want = ["deployment.proxy.type": "0",
                    "ows.jvm.manager.searchLocalAtStartup": "true",
                    "ows.jvm.manager.updateStrategy": "NO_REMOTE",
                    "ows.jvm.manager.customSearchLocation": searchDir,
                    "deployment.log": "true",
                    "deployment.log.file": "true",
                    "deployment.log.console": "true",
                    "deployment.log.console.clientapp": "true",   // the viewer's own stdout/stderr (OWS hides it otherwise)
                    "deployment.log.file.clientapp": "true",      // and to its own file
                    "deployment.log.stdstreams": "true",          // capture System.out/err of the app
                    "deployment.user.logdir": owsProfileConfig + "/icedtea-web/log"]
        var lines = (try? String(contentsOfFile: cfg, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        var seen = Set<String>()
        lines = lines.map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return line }
            let k = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            if let v = want[k] { seen.insert(k); return "\(k)=\(v)" }
            return line
        }
        for (k, v) in want where !seen.contains(k) { lines.append("\(k)=\(v)") }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: owsProfileCache, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(toFile: cfg, atomically: true, encoding: .utf8)
    }

    static func findJavaws() -> String? {
        var cands: [String] = []
        for base in ["/Applications", NSHomeDirectory() + "/Applications"] {
            cands += globFiles(base + "/Open Web Start*/javaws")
            cands += globFiles(base + "/OpenWebStart*/javaws")
            cands += globFiles(base + "/Open Web Start*/*javaws*.app")   // not Settings/Uninstaller
            cands += globFiles(base + "/OpenWebStart*/*javaws*.app")
        }
        if let u = jnlpDefaultApp() { cands.append(u.path) }
        cands += ["/usr/local/bin/javaws", "/opt/homebrew/bin/javaws",
                  NSHomeDirectory() + "/.local/bin/javaws"]
        for c in cands {
            if let bin = resolveJavawsBinary(c), bin != "/usr/bin/javaws" { return bin }
        }
        return nil
    }

    // Turn a path (a binary, or an OpenWebStart .app bundle) into a runnable javaws executable.
    static func resolveJavawsBinary(_ path: String) -> String? {
        let fm = FileManager.default
        if path.hasSuffix(".app") {
            let direct = path + "/Contents/MacOS/javaws"
            if fm.isExecutableFile(atPath: direct) { return direct }
            if let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
               let exe = info["CFBundleExecutable"] as? String {
                let inner = path + "/Contents/MacOS/" + exe
                if fm.isExecutableFile(atPath: inner) { return inner }
            }
            return nil
        }
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    // The app currently registered to open .jnlp files, if any.
    static func jnlpDefaultApp() -> URL? {
        let probe = URL(fileURLWithPath: NSTemporaryDirectory() + "iKVM-probe.jnlp")
        try? Data().write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }
        if #available(macOS 12.0, *) { return NSWorkspace.shared.urlForApplication(toOpen: probe) }
        return nil
    }

    static func dockerAvailable() -> Bool {
        containerCLIs.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAppleSilicon: Bool {
        var ret: Int32 = 0; var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &ret, &size, nil, 0) == 0 { return ret == 1 }
        return false
    }

    static var rosettaInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
            || fm.fileExists(atPath: "/Library/Apple/usr/libexec/oah")
    }

    // The engine run.sh uses (Preferences): podman without a docker command; with one, the engine
    // whose socket is there (run.sh's order), else the one run.sh would start.
    static var engineInUse: String? {
        let fm = FileManager.default
        guard let cli = containerCLIs.first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
        if cli.hasSuffix("/podman") { return "Podman" }
        func isSocket(_ p: String) -> Bool {
            (try? fm.attributesOfItem(atPath: p)[.type] as? FileAttributeType) == .typeSocket
        }
        let sockets = [(HOME + "/.orbstack/run/docker.sock", "OrbStack"), (HOME + "/.docker/run/docker.sock", "Docker Desktop"),
                       (HOME + "/.colima/default/docker.sock", "Colima"), (HOME + "/.rd/docker.sock", "Rancher Desktop")]
        for (s, name) in sockets where isSocket(s) { return name }
        if fm.fileExists(atPath: "/Applications/OrbStack.app") { return "OrbStack" }
        if fm.fileExists(atPath: "/Applications/Docker.app") { return "Docker Desktop" }
        if ["/opt/homebrew/bin/colima", "/usr/local/bin/colima"].contains(where: { fm.isExecutableFile(atPath: $0) }) { return "Colima" }
        return "docker"
    }

    // Container engines installed on this Mac (for display).
    static func containerRuntimes() -> [String] {
        let fm = FileManager.default
        let checks: [(String, [String])] = [
            ("Docker Desktop", ["/Applications/Docker.app"]),
            ("OrbStack", ["/Applications/OrbStack.app", "/usr/local/bin/orbstack"]),
            ("Colima",   ["/opt/homebrew/bin/colima", "/usr/local/bin/colima"]),
            ("Podman",   ["/opt/podman/bin/podman", "/opt/homebrew/bin/podman", "/usr/local/bin/podman"]),
        ]
        var found: [String] = []
        for (name, paths) in checks where paths.contains(where: { fm.fileExists(atPath: $0) }) { found.append(name) }
        if found.isEmpty && fm.isExecutableFile(atPath: "/opt/homebrew/bin/docker") { found.append("docker") }
        return found
    }

    // The status dot: green everything works as it should, yellow everything works with a
    // shortcoming, orange only IPMIView or only .jnlp files, red nothing.
    enum Health { case ok, minor, limited, bad }
    var health: (level: Health, text: String) {
        let fm = FileManager.default
        let hasIPMIView = fm.fileExists(atPath: ipmiview + "/IPMIView20.jar")
        if useContainer {
            let rt = Model.containerRuntimes()
            if rt.isEmpty { return (.bad, "No container runtime found — install OrbStack, Docker, Podman, or Colima") }
            if !Model.dockerAvailable() {
                return (.bad, "No docker or podman command — Colima needs Homebrew's: brew install docker")
            }
            if !hasIPMIView { return (.limited, "Only .jnlp files — set the IPMIView folder") }
            let engine = Model.engineInUse ?? rt.joined(separator: ", ")
            if passwordNeeded && vncPassword.isEmpty {
                return (.bad, "The consoles need a password — Preferences › Container › Security")
            }
            // TigerVNC Viewer: better keys and clipboard than a browser (Preferences › Container),
            // missing only where the consoles would open in it (Automatic, TigerVNC Viewer)
            if Model.tigerVNCApp == nil && (vncChoice == "auto" || vncChoice == "tiger") {
                return (.minor, "Container ready (\(engine)) — but TigerVNC Viewer isn't installed: brew install --cask tigervnc-viewer")
            }
            return (.ok, "Container ready (\(engine))")
        }
        if Model.isAppleSilicon && !Model.rosettaInstalled {
            return (.bad, Model.dockerAvailable()
                ? "Apple Silicon without Rosetta — install it, or run in a container"
                : "Apple Silicon without Rosetta or a container runtime")
        }
        // IPMIView: its folder, an Intel Java (the script's default if none is set); its KVM console
        // also stunnel (IPMIView starts without, with a note below "Launch KVM Console")
        let java = intelJava.isEmpty ? "/Library/Java/JavaVirtualMachines/temurin-11.jre/Contents/Home" : intelJava
        var missing: [String] = []
        if !hasIPMIView { missing.append("set the IPMIView folder") }
        if !fm.isExecutableFile(atPath: java + "/bin/java") { missing.append("set an Intel Java") }
        // .jnlp files: OpenWebStart, else the container
        let jnlpNative = resolvedJavaws != nil
        let jnlp = jnlpNative || Model.dockerAvailable()
        switch (missing.isEmpty, jnlp) {
        case (false, false):
            return (.bad, "Nothing can start — " + (missing + ["install OpenWebStart"]).joined(separator: ", "))
        case (true, false):
            return (.limited, "Only IPMIView — install OpenWebStart to open .jnlp files"
                + (Model.stunnelInstalled ? "" : "; its KVM console needs stunnel: brew install stunnel"))
        case (false, true):
            return (.limited, "Only .jnlp files — IPMIView: " + missing.joined(separator: ", "))
        case (true, true):
            if !Model.stunnelInstalled { return (.minor, "Ready — but IPMIView's KVM console needs stunnel: brew install stunnel") }
            if !jnlpNative { return (.minor, "Ready — .jnlp files open in the container (no OpenWebStart)") }
            return (.ok, Model.isAppleSilicon ? "Ready (native via Rosetta)" : "Ready (native)")
        }
    }

    // Homebrew's stunnel: IPMIView's console tunnel (ipmiview-keypasta.sh stops without it); the
    // agent runs a .jnlp viewer's own stunnel as this one too (else from a fixed copy). Same places
    // as the agent's Spawn.
    static var stunnelInstalled: Bool {
        ["/opt/homebrew/bin/stunnel", "/usr/local/bin/stunnel"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func osaEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - UI
// The log: selectable, follows new output while scrolled to its end; scrolled up, it stays there
// (until scrolled back down). New output is appended, not the whole text set again.
struct LogView: NSViewRepresentable {
    let text: String
    private static let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.font = LogView.font
            tv.textColor = .textColor
            tv.backgroundColor = .textBackgroundColor
            tv.textContainerInset = NSSize(width: 2, height: 4)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let old = storage.string as NSString
        let new = text as NSString
        if new.isEqual(to: old as String) { return }
        // following: the end in view (or all of it fits) before the new text
        let following = scroll.contentView.bounds.maxY >= tv.bounds.maxY - 16
        let attrs: [NSAttributedString.Key: Any] = [.font: LogView.font, .foregroundColor: NSColor.textColor]
        if new.length > old.length && new.hasPrefix(old as String) {
            storage.append(NSAttributedString(string: new.substring(from: old.length), attributes: attrs))
        } else {
            storage.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        }
        if following { tv.scrollToEndOfDocument(nil) }
    }
}

struct PathRow: View {
    let label: String
    @Binding var value: String
    var pickDirectory: Bool
    var onDetect: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            HStack {
                TextField("", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                if let onDetect { Button("Detect") { onDetect() } }
                Button("Browse…") { choose() }
            }
        }
    }
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = pickDirectory
        panel.canChooseFiles = !pickDirectory
        panel.allowsMultipleSelection = false
        if !value.isEmpty { panel.directoryURL = URL(fileURLWithPath: value) }
        if panel.runModal() == .OK, let url = panel.url { value = url.path }
    }
}

func healthColor(_ h: Model.Health) -> Color {
    switch h { case .ok: return .green; case .minor: return .yellow; case .limited: return .orange; case .bad: return .red }
}

struct HealthBadge: View {
    let level: Model.Health
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(healthColor(level)).frame(width: 9, height: 9)
            Text(text).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// The launch button: two lines (macOS push buttons have a fixed height), default-button colors.
struct LaunchButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .foregroundColor(.white)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct MainView: View {
    @ObservedObject var m: Model
    @State private var dropTargeted = false
    @State private var logShown = false             // collapsed at every start
    @State private var optionHeld = false           // the Open buttons show their other way
    @State private var flagsMonitor: Any?

    private var logOpen: Bool { logShown }

    var body: some View {
        VStack(spacing: 14) {
            // IPMIView's container running: the button opens its console (starting it again would
            // replace the container, and close IPMIView and its viewers)
            Button {
                let alt = NSEvent.modifierFlags.contains(.option)
                if m.containerRunning { m.openBrowserConsole(alternate: alt) } else { m.launch(alternate: alt) }
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: m.containerRunning ? "macwindow" : "play.rectangle.fill")
                            .frame(width: 18, height: 16)
                        Text(m.launchingIPMIView ? "Starting IPMIView…" : m.containerRunning ? "Open IPMIView"
                             : m.ipmiviewRunning ? "IPMIView is running" : (m.containerBusy ? "Working…" : "Launch IPMIView"))
                    }
                    .font(.headline)
                    Text(m.containerRunning ? (optionHeld ? m.alternateOpenLabel.lowercased() : "its console, from the container")
                         : (optionHeld && m.useContainer ? "its console " + m.alternateWhere : "with iKVM console + keyboard fixes"))
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LaunchButtonStyle()).keyboardShortcut(.defaultAction)
            .disabled(!m.containerRunning && (m.ipmiviewRunning || m.containerBusy || m.ipmiview.isEmpty))

            // JNLP: drop target (also click to choose)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundColor(dropTargeted ? .accentColor : .gray.opacity(0.5))
                .frame(height: 84)
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.down.doc").frame(height: 17)
                        Text(m.launchingJnlp > 0 ? "Starting the .jnlp…"
                             : "Drop a .jnlp here, or click to choose" + (optionHeld && m.useContainer ? ": opens " + m.alternateWhere : ""))
                            .font(.caption)
                    }.foregroundColor(dropTargeted ? .accentColor : .secondary)
                )
                .onTapGesture { if !(m.useContainer && m.containerBusy) { m.openJnlp() } }
                .onDrop(of: ["public.file-url"], isTargeted: $dropTargeted) { m.handleDrop($0) }

            // the newest of the BMCs' launch.jnlp in Downloads: browsers save another one as
            // "launch (1).jnlp" and so on
            let newest = m.downloadsJnlp
            Button { if let j = newest { m.launchJnlp(j, alternate: NSEvent.modifierFlags.contains(.option)) } } label: {
                Label("Open Downloads/" + (newest.map { ($0 as NSString).lastPathComponent } ?? "launch.jnlp")
                      + (optionHeld && m.useContainer ? " " + m.alternateWhere : ""),
                      systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .disabled((m.useContainer && m.containerBusy) || newest == nil)
            .help(newest.map { "The newest launch.jnlp in Downloads: " + $0 } ?? "No launch.jnlp in your Downloads folder")

            // Running containers, set apart from the start buttons above: Open console as set in
            // Preferences, Option-click the other way; the addresses on the name's tooltip
            if m.containerRunning || !m.jnlpConsoles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Divider().padding(.bottom, 4)
                    if m.containerRunning {
                        Text("IPMIView").font(.caption).foregroundColor(.secondary)
                        HStack {
                            Text("Container").font(.caption).help(Model.addresses(Model.consolePort))
                            Spacer()
                            Button(optionHeld ? m.alternateOpenLabel : "Open console") {
                                m.openConsole(Model.consolePort, tips: true, alternate: NSEvent.modifierFlags.contains(.option))
                            }
                            Button("Stop", role: .destructive) { m.stopContainer() }
                                .help("Ends IPMIView and its consoles, and removes the container")
                        }
                        // its iKVM viewers, each in a tab of its own: opened the way IPMIView's
                        // console was last (Option-click: the other way)
                        ForEach(m.viewerTabPorts, id: \.self) { port in
                            HStack {
                                Text(m.viewerNames[port].map { "iKVM " + $0 } ?? "iKVM Viewer " + String(port - 6100))
                                    .font(.caption).help(Model.addresses(port))
                                Spacer()
                                Button(optionHeld ? (m.viewersViaVNC ? "Open in Browser" : "Open in VNC app") : "Open console") {
                                    m.openConsole(port, tab: true, alternate: NSEvent.modifierFlags.contains(.option), via: m.viewersViaVNC)
                                }
                                let stopping = m.stoppingViewers.contains(port)
                                Button(role: .destructive) { m.stopViewer(port) } label: {
                                    if stopping {
                                        ProgressView().controlSize(.small).scaleEffect(0.6)
                                            .frame(width: 28, height: 14)
                                    } else {
                                        Text("Stop")
                                    }
                                }
                                .disabled(stopping)
                                .help(stopping ? "Ending this viewer…" : "Ends this viewer; IPMIView keeps running")
                            }
                            .padding(.leading, 12)
                        }
                    }
                    if !m.jnlpConsoles.isEmpty {
                        Text(".jnlp").font(.caption).foregroundColor(.secondary)
                            .padding(.top, m.containerRunning ? 6 : 0)
                        ForEach(m.jnlpConsoles, id: \.self) { port in
                            HStack {
                                Text("Console " + String(port - 6200)).font(.caption).help(Model.addresses(port))
                                Spacer()
                                Button(optionHeld ? m.alternateOpenLabel : "Open console") {
                                    m.openConsole(port, alternate: NSEvent.modifierFlags.contains(.option))
                                }
                                Button("Stop", role: .destructive) { m.stopJnlp(port) }
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button { logShown.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: logShown ? "chevron.down" : "chevron.right")
                            Text("Log")
                        }
                        .font(.caption).foregroundColor(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if m.starting {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                            .help("Starting: IPMIView, a .jnlp, or a container")
                    }
                }
                .frame(height: 14)
                if logShown {
                    LogView(text: m.log)
                        .frame(minHeight: 84, maxHeight: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)    // collapsed too: the header stays left

            // the status, and Preferences (also the app menu, Cmd+,) at the lower right
            HStack(alignment: .center, spacing: 8) {
                HealthBadge(level: m.health.level, text: m.health.text)
                Spacer(minLength: 0)
                if #available(macOS 14.0, *) {
                    SettingsLink { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                        .help("Preferences (⌘,)")
                } else {
                    Button { Model.openPreferences() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                        .help("Preferences (⌘,)")
                }
            }
        }
        // With the log open the window is resizable (the log takes the height); without it (none
        // yet, or collapsed) the window is as high as its content: it shrinks and grows with the
        // log, its top edge staying (windowResizability(.contentSize))
        .padding(20)
        .frame(minWidth: 420, idealWidth: 420, maxWidth: 900,
               minHeight: logOpen ? 440 : nil, idealHeight: logOpen ? 440 : nil,
               maxHeight: logOpen ? CGFloat.infinity : nil, alignment: .top)
        .fixedSize(horizontal: false, vertical: !logOpen)
        .onAppear {
            AppDelegate.model = m
            m.handleLaunchArgs()
            m.detectRunningContainers()
            m.watchDownloads()
            if flagsMonitor == nil {
                flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
                    optionHeld = e.modifierFlags.contains(.option)
                    return e
                }
            }
        }
    }
}

// Preferences: General (both modes), then Native and Container in the order "Run in"
// shows them; the status dot top left on each (SettingsStatus).
struct SettingsView: View {
    @ObservedObject var m: Model

    var body: some View {
        TabView {
            GeneralSettings(m: m).tabItem { Label("General", systemImage: "gearshape") }
            NativeSettings(m: m).tabItem { Label("Native", systemImage: "desktopcomputer") }
            ContainerSettings(m: m).tabItem { Label("Container", systemImage: "shippingbox") }
        }
    }
}

// A tab's page: as high as its content, the window following it
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content() }
            .padding(20)
            .frame(width: 560, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.headline) }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
        }
    }
}

// A label on the left, its control on the right, an optional note below
struct SettingRow<Control: View>: View {
    let label: String
    var note: String? = nil
    @ViewBuilder var control: () -> Control
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer(minLength: 12)
                control()
            }
            if let note { SettingNote(text: note) }
        }
    }
}

// Containers take these settings at their start: a lock's note (the control disabled) or a
// warning that running ones keep theirs
struct ContainerNote: View {
    let show: Bool
    var locked = false
    var body: some View {
        if show {
            Text(locked ? "Can't change while container is running." : "Does not apply to running containers.")
                .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingNote: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// The status dot, top left on every tab: the main window's (Model.health); on the Native and
// Container tabs of the mode not chosen in Run in, grey and saying so.
struct SettingsStatus: View {
    @ObservedObject var m: Model
    var container: Bool? = nil      // the Container tab (true), the Native tab (false), else nil
    var body: some View {
        if let container, container != m.useContainer {
            HStack(spacing: 6) {
                Circle().fill(Color.gray.opacity(0.6)).frame(width: 9, height: 9)
                Text(container ? "Not used: the consoles run natively (General › Run in)"
                               : "Not used: the consoles run in the container (General › Run in)")
                    .font(.caption).foregroundColor(.secondary)
            }
        } else {
            HealthBadge(level: m.health.level, text: m.health.text)
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var m: Model
    var body: some View {
        SettingsPage {
            SettingsStatus(m: m)
            SettingsGroup {
                PathRow(label: "IPMIView folder", value: $m.ipmiview, pickDirectory: true,
                        onDetect: { m.detectIPMIView(force: true) })
                SettingRow(label: "Run in",
                           note: "Container: the whole console in an amd64 Linux container, in your browser or "
                               + "TigerVNC Viewer; the only way from macOS 28 on. Its first start builds the image "
                               + "(a download). Native: IPMIView and the viewer on this Mac, through Rosetta 2.") {
                    Picker("", selection: $m.useContainer) {
                        Text("Native").tag(false)
                        Text("Container").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            SettingsGroup {
                SettingRow(label: "Accept expired firmware certificate",
                           note: "For BMC firmware whose iKVM certificate is valid from 19 May 2016 to 17 May 2026 "
                               + "(e.g. X10, firmware 03.93): the BMC checks IPMIView's certificate against its "
                               + "own clock, so set that clock to a date in this range too. The console stays "
                               + "encrypted, but the BMC's identity isn't checked. Leave off with current firmware "
                               + "(certificates valid until 2041).") {
                    Toggle("", isOn: $m.disableTLS).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

struct NativeSettings: View {
    @ObservedObject var m: Model
    var body: some View {
        SettingsPage {
            SettingsStatus(m: m, container: false)
            SettingsGroup {
                VStack(alignment: .leading, spacing: 4) {
                    PathRow(label: "Viewer Java", value: $m.intelJava, pickDirectory: true,
                            onDetect: { m.detectIntelJava(force: true) })
                    SettingNote(text: "An x86_64 Java 8 or 11; it runs through Rosetta 2 (gone in macOS 28).")
                }
                VStack(alignment: .leading, spacing: 4) {
                    PathRow(label: "OpenWebStart", value: $m.javawsPath, pickDirectory: false,
                            onDetect: { m.detectJavaws(force: true) })
                    SettingNote(text: "To open .jnlp files natively; without it they open in the container.")
                }
            }
        }
    }
}

struct ContainerSettings: View {
    @ObservedObject var m: Model
    var body: some View {
        let tiger = Model.tigerVNCApp
        let tigerNote = tiger == nil ? "TigerVNC Viewer isn't installed: brew install --cask tigervnc-viewer."
                                     : "Found: " + Model.appName(tiger!) + "."
        SettingsPage {
            SettingsStatus(m: m, container: true)
            SettingsGroup {
                let rt = Model.containerRuntimes()
                SettingRow(label: "Engine",
                           note: rt.isEmpty ? "Install OrbStack, Docker Desktop, Podman, or Colima (brew install colima docker)."
                                            : "Detected: " + rt.joined(separator: ", ") + ". Reaching the BMCs is the engine's business (see the README).") {
                    Text(Model.engineInUse.map { $0 + " · in use" } ?? "none").foregroundColor(.secondary)
                }
            }
            SettingsGroup(title: "Consoles") {
                SettingRow(label: "VNC app",
                           note: "The consoles open in the VNC app; with none, in the browser. "
                               + "Option-click Open console: the other one."
                               + (m.vncChoice == "auto" || m.vncChoice == "tiger" ? " " + tigerNote : "")) {
                    Picker("", selection: $m.vncChoice) {
                        Text("Automatic: TigerVNC Viewer, else none").tag("auto")
                        Text("None: the browser").tag("none")
                        Divider()
                        Text("TigerVNC Viewer" + (tiger == nil ? " (not installed)" : "")).tag("tiger")
                        ForEach(m.vncApps, id: \.self) { app in
                            Text(Model.appName(app)).tag("app:" + app)
                        }
                        Divider()
                        Text("Select other…").tag("other")
                        Text("Custom command").tag("command")
                    }
                    .labelsHidden().fixedSize()
                }
                if m.vncChoice == "command" {
                    TextField(Model.vncCommandExample, text: $m.vncCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    SettingNote(text: "A shell command; ${HOST} and ${VNCPORT} are the console's VNC address "
                                    + "(keep them in double quotes). For example TigerVNC in fullscreen:")
                    Text(Model.vncCommandExample)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingRow(label: "Browser") {
                    Picker("", selection: $m.browserChoice) {
                        Text("Automatic: Chrome or Edge, else the default").tag("auto")
                        Text("Default browser" + (m.defaultBrowserName.map { " (\($0))" } ?? "")).tag("default")
                        Divider()
                        ForEach(m.browserApps, id: \.self) { app in
                            Text(Model.appName(app)).tag("app:" + app)
                        }
                        Divider()
                        Text("Select other…").tag("other")
                        Text("Custom command").tag("command")
                    }
                    .labelsHidden().fixedSize()
                }
                if m.browserChoice == "command" {
                    TextField(Model.browserCommandExample, text: $m.browserCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    SettingNote(text: "A shell command; ${URL} is the console's browser address (keep it in double "
                                    + "quotes). For example Chrome, profile \"Profile 1\" (its folder name, from "
                                    + "chrome://version), app mode:")
                    Text(Model.browserCommandExample)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingRow(label: "Each iKVM Viewer in a tab or window of its own",
                           note: "Up to 99 at a time. Off: they open as windows next to IPMIView. "
                               + "Takes effect at the next start.") {
                    Toggle("", isOn: $m.viewerTabs).labelsHidden().toggleStyle(.switch)
                        .disabled(m.ipmiviewContainerActive)
                }
                ContainerNote(show: m.ipmiviewContainerActive, locked: true)
            }
            SettingsGroup(title: "Keyboard") {
                let detected = Model.containerLayout
                SettingRow(label: "Keyboard layout in the container",
                           note: "For typing in the container itself (IPMIView's fields, IcedTea-Web's dialogs). "
                               + "The BMC's layout, the paste hotkey and the Alt/GUI swap are set in the viewer: "
                               + "Options › KeyPasta Preferences.") {
                    Picker("", selection: $m.containerLayoutChoice) {
                        Text("Automatic (" + Model.layoutName(detected) + ")").tag("auto")
                        Divider()
                        ForEach(Model.containerLayouts.indices, id: \.self) { i in
                            Text(Model.containerLayouts[i].1).tag(Model.containerLayouts[i].0)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                ContainerNote(show: m.anyContainerActive)
            }
            SettingsGroup(title: "Folders in the container") {
                PathRow(label: "Virtual media, /root/vMedia (blank = none)", value: $m.isoDir, pickDirectory: true)
                PathRow(label: "Screenshots and recordings, /root/screencap (blank = none)",
                        value: $m.screencapDir, pickDirectory: true)
                ContainerNote(show: m.anyContainerActive)
            }
            SettingsGroup(title: "Security") {
                ContainerNote(show: m.anyContainerActive, locked: true)
                Group {
                    SettingRow(label: "This Mac only") {
                        Toggle("", isOn: $m.localOnly).labelsHidden().toggleStyle(.switch)
                    }
                    if m.localOnly {
                        SettingNote(text: "The consoles are reachable at localhost only. Takes effect at the next "
                                        + "start of a container.")
                    } else {
                        Text("Reachable from the network: anyone who can reach this Mac gets IPMIView, with its saved "
                             + "BMC logins. So \"Accept any VNC password\" is off: the password below, for the browser "
                             + "view too. Takes effect at the next start of a container.")
                            .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    SettingRow(label: "Accept any VNC password",
                               note: "On: no password asked by TigerVNC Viewer and the browser; a VNC app that wants one "
                                   + "may give whatever it likes, empty too. Off: the password below, "
                                   + "for every VNC app and the browser view.") {
                        Toggle("", isOn: $m.acceptAnyPassword).labelsHidden().toggleStyle(.switch)
                            .disabled(!m.localOnly)
                    }
                    if m.passwordNeeded {
                        SettingRow(label: "Password",
                                   note: "VNC uses its first 8 characters. Kept in ~/Library/Application Support/"
                                       + "iKVM-KeyPasta, readable by you only. Takes effect at the next start of a container.") {
                            SecureField("", text: $m.vncPassword)
                                .textFieldStyle(.roundedBorder).frame(width: 200)
                        }
                        if m.vncPassword.isEmpty {
                            Text("Needed to start a container.")
                                .font(.caption).foregroundColor(.orange)
                        }
                    }
                }
                .disabled(m.anyContainerActive)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: Model?
    private var appearanceObservation: NSKeyValueObservation?

    // The Dock icon follows dark/light mode (the static app icon can't without an asset catalog).
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false       // no View › Show Tab Bar
        updateDockIcon()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateDockIcon() }
        }
    }

    private func updateDockIcon() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let path = Bundle.main.path(forResource: dark ? "AppIcon-dark" : "AppIcon-light", ofType: "icns"),
           let image = NSImage(contentsOfFile: path) {
            NSApp.applicationIconImage = image
        }
    }
    // The viewers run as this app's children (their output comes through its pipes): quitting
    // ends them, and their remote sessions with them. Ask first while any is running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let m = AppDelegate.model, m.anyRunning else { return .terminateNow }
        var what: [String] = []
        if m.ipmiviewRunning { what.append("IPMIView and the KVM consoles it opened") }
        if m.jnlpRunning > 0 { what.append(m.jnlpRunning == 1 ? "1 iKVM viewer (JNLP)" : "\(m.jnlpRunning) iKVM viewers (JNLP)") }
        if m.containerBusy { what.append("the container") }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit iKVM-KeyPasta?"
        alert.informativeText = "Still running: " + what.joined(separator: ", ")
            + ". Quitting closes them too, and their remote console connections are disconnected."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        if let u = urls.first(where: { $0.pathExtension.lowercased() == "jnlp" }) {
            AppDelegate.model?.launchJnlp(u.path)
        }
    }
}

// The standard About panel (name, icon, version from Info.plist) with a short notice and a link
// to the project page in its credits.
enum AboutApp {
    static let projectURL = URL(string: "https://github.com/Tabiskabis/iKVM-KeyPasta")!

    static func show() {
        let left = NSMutableParagraphStyle()
        left.alignment = .left
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: left,
        ]
        let credits = NSMutableAttributedString(
            string: "Runs Supermicro's IPMIView and the BMCs' .jnlp iKVM viewers on this Mac, natively or "
                + "in a container, with the iKVM-KeyPasta keyboard fixes and paste.\nNot affiliated with "
                + "Supermicro or ATEN.\n\n",
            attributes: plain)
        var link = plain
        link[.link] = projectURL
        credits.append(NSAttributedString(string: "github.com/Tabiskabis/iKVM-KeyPasta", attributes: link))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

@main
struct IPMIViewKeyPastaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model()
    var body: some Scene {
        // one window: no File › New Window, no tabs (Window, not WindowGroup; tabbing off)
        Window("iKVM-KeyPasta", id: "main") {
            MainView(m: model)
        }
        .windowResizability(.contentSize)
        // File › Open….jnlp (Cmd+O) in place of New Window
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open .jnlp…") { model.openJnlp() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.useContainer && model.containerBusy)
            }
            // About: what the app is, and the project page; Help: the project page (no help book)
            CommandGroup(replacing: .appInfo) {
                Button("About iKVM-KeyPasta") { AboutApp.show() }
            }
            CommandGroup(replacing: .help) {
                Button("iKVM-KeyPasta on GitHub") { NSWorkspace.shared.open(AboutApp.projectURL) }
            }
        }
        Settings {
            SettingsView(m: model)
        }
    }
}
