// IPMIView KeyPasta launcher — a stable macOS app bundle that starts IPMIView's KVM console
// with the Java agent and (optionally) a relaxed TLS check for BMCs with an expired iKVM cert.
//
// Its purpose beyond the GUI: it is ONE fixed app identity. Grant Accessibility, Input
// Monitoring, Local Network and the firewall to this app once; the viewer (java) and the
// tunnel (stunnel) run as its children and inherit the grant, so nothing re-prompts.
//
// All the real work lives in the bundled ipmiview-keypasta.sh; this app only collects the
// paths/checkbox and runs that script with them as environment variables.

import SwiftUI
import AppKit
import IOKit.hid
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
    // Where the container's consoles open: "auto" (a Chromium browser if installed, else the
    // default), "default", "app:<path>", "command" (browserCommand, ${URL} = the console's address)
    @Published var browserChoice: String { didSet { browserChoiceChanged(oldValue) } }
    @Published var browserCommand: String { didSet { save("browserCommand", browserCommand) } }
    @Published var customBrowsers: [String] { didSet { UserDefaults.standard.set(customBrowsers, forKey: "customBrowsers") } }
    // The agent's paste hotkey (its syntax, see Config.java), for the viewers and the browser view
    @Published var pasteHotkey: String { didSet { save("pasteHotkey", pasteHotkey) } }
    static let defaultPasteHotkey = "alt+shift+V"
    @Published var isoDir: String { didSet { save("isoDir", isoDir) } }
    @Published var screencapDir: String { didSet { save("screencapDir", screencapDir) } }
    @Published var log = ""
    // What's running: IPMIView only once at a time; any number of .jnlp viewers, also next to it.
    enum RunKind { case ipmiview, jnlp, container }
    @Published var ipmiviewRunning = false
    @Published var jnlpRunning = 0
    @Published var containerBusy = false
    var anyRunning: Bool { ipmiviewRunning || jnlpRunning > 0 || containerBusy }
    @Published var containerRunning = false
    // Starting, until its window (native: the app named "IPMIView"/"iKVM Viewer" in the Dock) or
    // its console (container) is there: a throbber instead of the button's symbol
    @Published var launchingIPMIView = false
    @Published var launchingJnlp = 0
    // .jnlp consoles in containers of their own (ikvm-jnlp-PORT), next to IPMIView's: their ports
    @Published var jnlpConsoles: [Int] = []
    @Published var ledAccess = false        // Input Monitoring, see checkInputMonitoring

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
        customBrowsers = d.stringArray(forKey: "customBrowsers") ?? []
        pasteHotkey = d.string(forKey: "pasteHotkey") ?? Model.defaultPasteHotkey
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
        let roots = ["/Applications/IPMIView*", "\(HOME)/Applications/IPMIView*",
                     "\(HOME)/.local/bin/IPMIView*", "/opt/IPMIView*", "\(HOME)/IPMIView*",
                     "/opt/iKVM*/IPMIView*"]
        for pat in roots {
            for cand in globFiles(pat).sorted() {
                if has(cand) { ipmiview = cand; return }
                for sub in globFiles(cand + "/*") where has(sub) { ipmiview = sub; return }
            }
        }
    }

    func detectIntelJava(force: Bool) {
        guard force || intelJava.isEmpty else { return }
        let fm = FileManager.default
        let homes = globFiles("/Library/Java/JavaVirtualMachines/*/Contents/Home")
                    .filter { fm.fileExists(atPath: $0 + "/bin/java") }
        if let pick = homes.first(where: { $0.contains("temurin-11") || $0.contains("-11.") }) ?? homes.first {
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

    // MARK: Input Monitoring
    // iKVM's macOS library reads and sets the keyboard LEDs (CapsLock) through the keyboard's HID
    // device, and quits the viewer when macOS refuses that (any dialog, focus change, lock key; see
    // the agent's Native class). It needs Input Monitoring, granted to this app (the Java processes
    // it starts count as this app).
    static let inputMonitoringPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

    var inputMonitoringGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    // At app start (native mode). Granted: the agent leaves the LEDs to iKVM (macLed=native). Not
    // granted: asked once per build of this app. macOS ties the grant to the exact build (ad-hoc
    // signature), keeps an earlier build's entry (shown as on, but not valid for this one) and then
    // doesn't ask by itself, so that entry is reset first. Declined or not yet switched on: the
    // agent's fallback (no LED access; the viewer keeps running, lock keys still work).
    @discardableResult
    func checkInputMonitoring() -> Bool {
        if inputMonitoringGranted { ledAccess = true; return true }
        let d = UserDefaults.standard
        if d.string(forKey: "inputMonitoringAskedFor") != Model.buildStamp {
            d.set(Model.buildStamp, forKey: "inputMonitoringAskedFor")
            var resetOK = false
            if let id = Bundle.main.bundleIdentifier {
                let r = Process()
                r.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                r.arguments = ["reset", "ListenEvent", id]
                r.standardOutput = FileHandle.nullDevice
                r.standardError = FileHandle.nullDevice
                if (try? r.run()) != nil { r.waitUntilExit(); resetOK = r.terminationStatus == 0 }
            }
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            // the same permission through CoreGraphics: puts the app in the list, switched off
            // (reported missing from the list with IOHIDRequestAccess alone)
            if #available(macOS 10.15, *) { _ = CGRequestListenEventAccess() }
            log += "macOS asks to allow Input Monitoring for this app: iKVM reads the keyboard LEDs "
                 + "(CapsLock) with it. Without it the viewer works too, just without LED sync.\n"
            if !resetOK {
                log += "If no question appears and the switch in Settings is already on: an earlier "
                     + "version's permission. Remove IPMIView KeyPasta there (−) and add it again (+).\n"
            }
        }
        ledAccess = inputMonitoringGranted
        return ledAccess
    }

    // Changes with every build of the app (version and the executable's date).
    static var buildStamp: String {
        let exe = Bundle.main.executablePath ?? ""
        let date = (try? FileManager.default.attributesOfItem(atPath: exe))?[.modificationDate] as? Date
        let ver = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "\(ver)-\(Int(date?.timeIntervalSince1970 ?? 0))"
    }

    // Dock names "IPMIView" and "iKVM Viewer" instead of "java" (java-name.sh, java-launcher).
    var launcherPath: String? { Bundle.main.path(forResource: "java-launcher", ofType: nil) }

    // Agent options for the native launches: the LEDs to iKVM only with Input Monitoring.
    var agentArgs: String {
        var a = "macLed=" + (ledAccess ? "native" : "fallback")
        // the agent's decisions (never typed keys), for diagnosis
        let logDir = NSHomeDirectory() + "/Library/Logs/iKVM-KeyPasta"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        if !logDir.contains(" ") { a += ",log=" + logDir + "/agent.log" }
        if let p = pasteArg { a += "," + p }
        return a
    }

    // The paste hotkey for the agent, if not its default (which on macOS also takes Cmd+Shift+V).
    var pasteArg: String? { pasteHotkey == Model.defaultPasteHotkey || pasteHotkey.isEmpty ? nil : "paste=" + pasteHotkey }

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

    func launch() {
        guard let script = Bundle.main.path(forResource: "ipmiview-keypasta", ofType: "sh") else {
            log = "Bundled ipmiview-keypasta.sh is missing.\n"; return
        }
        if useContainer { runContainer(jnlp: nil); return }
        guard !ipmiviewRunning else { log += "IPMIView is already running.\n"; return }
        ledAccess = inputMonitoringGranted
        log += "Keyboard LEDs: " + (ledAccess ? "iKVM's own (Input Monitoring allowed)" : "fallback (no Input Monitoring)") + "\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script]

        var env = ProcessInfo.processInfo.environment
        if !ipmiview.isEmpty  { env["IPMIVIEW"]   = ipmiview }
        if !effectiveAgent.isEmpty { env["AGENT"] = effectiveAgent; env["AGENT_ARGS"] = agentArgs }
        if let l = launcherPath { env["KEYPASTA_LAUNCHER"] = l }
        if !intelJava.isEmpty { env["INTEL_JAVA"] = intelJava }
        env["IGNORE_EXPIRED_CERT"] = disableTLS ? "true" : "false"
        // A GUI app inherits a bare PATH; stunnel/javac live in Homebrew.
        env["PATH"] = NSHomeDirectory() + "/.orbstack/bin:/Applications/OrbStack.app/Contents/MacOS/xbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        launching(ipmiview: true)
        run(p, exitLabel: "IPMIView", kind: .ipmiview, onExit: { _ in self.launched(ipmiview: true) })
    }

    // Open a .jnlp (Java Web Start) and run it with the agent.
    func openJnlp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let jnlpType = UTType(filenameExtension: "jnlp") { panel.allowedContentTypes = [jnlpType] }
        if panel.runModal() == .OK, let url = panel.url { launchJnlp(url.path) }
    }

    func launchJnlp(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { log = "JNLP not found: \(path)\n"; return }
        if useContainer { runContainer(jnlp: path); return }
        guard let ws = resolvedJavaws else {
            if Model.dockerAvailable() {
                log = "OpenWebStart not found — opening the JNLP in the container instead.\n"
                runContainer(jnlp: path)
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
        ledAccess = inputMonitoringGranted
        Model.writeOWSProfile(searchDir: javaSearchDir)
        let p = Process()
        var env = ProcessInfo.processInfo.environment
        env["XDG_CONFIG_HOME"] = Model.owsProfileConfig
        env["XDG_CACHE_HOME"]  = Model.owsProfileCache
        if !effectiveAgent.isEmpty { env["JAVA_TOOL_OPTIONS"] = "-javaagent:\(effectiveAgent)=\(agentArgs)" }

        var launched = false
        if let r = ws.range(of: ".app/Contents/") {
            let root = ((String(ws[..<r.lowerBound]) + ".app") as NSString).deletingLastPathComponent
            let javaBin = root + "/.install4j/jre.bundle/Contents/Home/bin/java"
            let owsJar  = root + "/openwebstart.jar"
            let cp      = root + "/.install4j/i4jruntime.jar:" + owsJar
            if fm.isExecutableFile(atPath: javaBin), fm.fileExists(atPath: owsJar) {
                let javaArgs = ["-cp", cp, "net.sourceforge.jnlp.runtime.Boot", "-Xnofork", "-verbose", path]
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

    static let consolePort = 6080

    // A console's address (noVNC); keypasta_paste: the paste hotkey for keypasta.js in the page.
    // A viewer's own tab doesn't reconnect: its desktop is gone with the viewer.
    func consoleURL(_ port: Int, tab: Bool = false) -> String {
        let hotkey = pasteHotkey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "http://localhost:\(port)/novnc/vnc.html?autoconnect=1&resize=remote" + (tab ? "&reconnect=0" : "")
            + "&keypasta_paste=" + hotkey
    }

    // Build (first run) and start the container in the background, streaming output into the log.
    // No Terminal: the app runs it and opens macOS Screen Sharing once it is up.
    func runContainer(jnlp: String?) {
        guard !containerBusy else { return }
        guard let script = Bundle.main.path(forResource: "run", ofType: "sh", inDirectory: "container") else {
            log = "container/run.sh is missing from the app bundle (rebuild with build.sh).\n"; return
        }
        // invoke via bash so a missing +x bit on the bundled script can never block the launch
        // IPMIView's container on 6080; a .jnlp's its own, on a port run.sh picks (6090-6099)
        var parts = ["bash", Model.shq(script), "--detach"]
        if jnlp == nil             { parts += ["--port", "\(Model.consolePort)"] }
        if !ipmiview.isEmpty       { parts += ["--ipmiview", Model.shq(ipmiview)] }
        if !effectiveAgent.isEmpty { parts += ["--agent", Model.shq(effectiveAgent)] }
        if let p = pasteArg        { parts += ["--agent-args", Model.shq(p)] }
        if disableTLS              { parts += ["--relax"] }
        let layout = Model.containerLayout
        parts += ["--layout", Model.shq(layout)]
        if viewerTabs              { parts += ["--viewer-tabs"] }
        if !isoDir.isEmpty         { parts += ["--vmedia-dir", Model.shq(isoDir)] }
        if !screencapDir.isEmpty   { parts += ["--screencap-dir", Model.shq(screencapDir)] }
        if let j = jnlp            { parts += ["--jnlp", Model.shq(j)] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", parts.joined(separator: " ")]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = NSHomeDirectory() + "/.orbstack/bin:/Applications/OrbStack.app/Contents/MacOS/xbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        let note = "Keyboard layout in the container: \(layout) (from the Mac's input source)\n"
        let isIPMIView = jnlp == nil
        launching(ipmiview: isIPMIView)
        run(p, exitLabel: jnlp == nil ? "container start" : ".jnlp container start", kind: .container, onSuccess: { output in
            if jnlp == nil {
                self.containerRunning = true
                self.waitThenOpenConsole(Model.consolePort) { self.launched(ipmiview: true) }
                if self.viewerTabs { self.watchViewerTabs() }
                self.log += note
            } else if let port = Model.startedPort(in: output) {
                self.log += note
                if !self.jnlpConsoles.contains(port) { self.jnlpConsoles.append(port) }
                self.waitThenOpenConsole(port) { self.launched(ipmiview: false) }
                self.watchJnlpConsoles()
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

    // run.sh's "console-port: N"
    static func startedPort(in output: String) -> Int? {
        for line in output.split(separator: "\n") where line.hasPrefix("console-port: ") {
            return Int(line.dropFirst("console-port: ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // Poll the console port until the in-container VNC server is really listening, then open the
    // browser view (noVNC). The console is browser-only: host port 5900 is never used, so nothing
    // on the Mac can clash with it.
    func waitThenOpenConsole(_ port: Int, done: (() -> Void)? = nil) {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/bash")
        probe.arguments = ["-c", "for _ in $(seq 1 90); do curl -fsS -m 2 \"http://localhost:\(port)/novnc/vnc.html\" >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"]
        probe.terminationHandler = { proc in
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    self.log += "Console is up — opening it.\n"
                    self.openBrowser(self.consoleURL(port), tips: port == Model.consolePort)
                } else {
                    self.log += "The console didn't come up yet. When it does, click \"Browser\".\n"
                }
                done?()
            }
        }
        try? probe.run()
    }

    // Viewer tabs: each viewer the container starts gets a desktop of its own, served on the next
    // free port of 6081-6089 (container/entrypoint.sh). Polled every 2 s while the container runs:
    // a port whose noVNC page answers and didn't before is a new viewer: opened in a new tab. Docker
    // accepts connections on published ports even with nothing behind them, so the page itself is
    // asked for, not just the port; with curl, as waitThenOpenConsole does.
    private var tabTimer: Timer?
    private var tabsUp = Set<Int>()
    private var tabProbe: Process?

    func watchViewerTabs() {
        tabTimer?.invalidate()
        tabsUp.removeAll()
        log += "iKVM Viewers open in browser tabs of their own (ports 6081-6089).\n"
        tabTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.containerRunning else { self.tabTimer?.invalidate(); self.tabTimer = nil; return }
            if let running = self.tabProbe, running.isRunning { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "for p in $(seq 6081 6089); do ( curl -fsS -m 1.5 -o /dev/null \"http://localhost:$p/novnc/vnc.html\" 2>/dev/null && echo $p ) & done; wait"]
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
        for port in up.subtracting(tabsUp).sorted() {
            log += "iKVM Viewer in a new tab (port \(port)).\n"
            openBrowser(consoleURL(port, tab: true))
        }
        tabsUp = up
    }

    // The .jnlp containers end with their viewers (run.sh starts them to be removed): every 5 s,
    // while there are any, which still are.
    private var jnlpTimer: Timer?

    func watchJnlpConsoles() {
        guard jnlpTimer == nil else { return }
        jnlpTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.jnlpConsoles.isEmpty { self.jnlpTimer?.invalidate(); self.jnlpTimer = nil; return }
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
                        self.log += "The .jnlp console on port \(port) ended.\n"
                    }
                    self.jnlpConsoles.removeAll { !names.contains("ikvm-jnlp-\($0)") }
                }
            }
            try? p.run()
        }
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

    func openBrowserConsole() {
        openBrowser(consoleURL(Model.consolePort), tips: true)
    }

    // As chosen in Preferences (browserChoice); "auto": a Chromium browser if there is one
    // (fullscreen there captures Ctrl+Tab/Alt+Tab for the remote), else the default browser.
    func openBrowser(_ url: String, tips: Bool = false) {
        let fm = FileManager.default
        if browserChoice == "command" {
            let cmd = browserCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty {
                runBrowserCommand(cmd, url: url)
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

    // The user's browser command, by /bin/sh, with URL in its environment: "${URL}" in it is the
    // console's address (the shell puts it in, quoted as written); without it, it's appended.
    // Its error output (the first 2000 characters) goes to the log if it fails.
    func runBrowserCommand(_ cmd: String, url: String) {
        let line = cmd.contains("$URL") || cmd.contains("${URL}") ? cmd : cmd + " \"${URL}\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", line]
        var env = ProcessInfo.processInfo.environment
        env["URL"] = url
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
                    self.log += "The browser command failed (status \(proc.terminationStatus))"
                        + (text.isEmpty ? "" : ": " + text) + "\n"
                }
            }
        }
        do { try p.run() } catch { log += "The browser command couldn't start: \(error.localizedDescription)\n" }
    }

    static let browserCommandExample = "open -na \"Google Chrome\" --args --profile-directory=\"Profile 1\" --app=\"${URL}\""

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

    // The paste hotkey of a key press (Preferences' recorder): Control, Option or Command, and a
    // letter, digit (by the key's place on a US keyboard, as the agent and the container look for
    // it) or F1-F12; nil for anything else.
    static func hotkeySpec(_ e: NSEvent) -> String? {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f.contains(.control) || f.contains(.option) || f.contains(.command) else { return nil }
        let keys: [UInt16: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C",
            0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
            0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x19: "9", 0x1A: "7", 0x1C: "8", 0x1D: "0",
            0x1F: "O", 0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K", 0x2D: "N", 0x2E: "M",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
            0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12"]
        guard let key = keys[e.keyCode] else { return nil }
        var parts: [String] = []
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option)  { parts.append("alt") }
        if f.contains(.shift)   { parts.append("shift") }
        if f.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    // "alt+shift+V" -> "⌥⇧V"
    static func hotkeyLabel(_ spec: String) -> String {
        var parts = spec.split(separator: "+").map { $0.lowercased() }
        let key = parts.popLast().map { $0.uppercased() } ?? ""
        var label = ""
        if parts.contains("ctrl") || parts.contains("control") { label += "⌃" }
        if parts.contains("alt") || parts.contains("option")   { label += "⌥" }
        if parts.contains("shift")                             { label += "⇧" }
        if parts.contains("cmd") || parts.contains("meta")     { label += "⌘" }
        return label + key
    }

    func stopContainer() {
        try? Model.docker("rm -f ikvm-console").run()
        containerRunning = false
        log += "Container stopped.\n"
    }

    // A .jnlp dropped on the window.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for pr in providers {
            _ = pr.loadObject(ofClass: URL.self) { url, _ in
                if let u = url, u.pathExtension.lowercased() == "jnlp" {
                    DispatchQueue.main.async { self.launchJnlp(u.path) }
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

    // Container runtimes detected on this Mac (for display).
    static func containerRuntimes() -> [String] {
        let fm = FileManager.default
        let checks: [(String, [String])] = [
            ("Docker",   ["/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]),
            ("OrbStack", ["/Applications/OrbStack.app", "/usr/local/bin/orbstack"]),
            ("Colima",   ["/opt/homebrew/bin/colima", "/usr/local/bin/colima"]),
            ("Podman",   ["/opt/podman/bin/podman", "/opt/homebrew/bin/podman", "/usr/local/bin/podman"]),
        ]
        var found: [String] = []
        for (name, paths) in checks where paths.contains(where: { fm.fileExists(atPath: $0) }) { found.append(name) }
        if found.isEmpty && fm.isExecutableFile(atPath: "/opt/homebrew/bin/docker") { found.append("Docker") }
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
            if !hasIPMIView { return (.limited, "Only .jnlp files — set the IPMIView folder below") }
            return (.ok, "Container ready (\(rt.joined(separator: ", ")))")
        }
        if Model.isAppleSilicon && !Model.rosettaInstalled {
            return (.bad, Model.dockerAvailable()
                ? "Apple Silicon without Rosetta — install it, or turn on container mode"
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
            if !inputMonitoringGranted { return (.minor, "Ready — keyboard LEDs not synced (Input Monitoring off)") }
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

// The paste hotkey: shown as ⌥⇧V; "Record…" takes the next key pressed with Control, Option or
// Command (Esc: cancel).
struct HotkeyField: View {
    @Binding var value: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var note = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack {
                Text(recording ? "Press the keys…" : Model.hotkeyLabel(value))
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 90, alignment: .trailing)
                Button(recording ? "Cancel" : "Record…") { recording ? stop() : start() }
                Button("Default") { value = Model.defaultPasteHotkey }
                    .disabled(recording || value == Model.defaultPasteHotkey)
            }
            if !note.isEmpty { Text(note).font(.caption).foregroundColor(.orange) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        note = ""
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 0x35 {                       // Esc
                stop()
            } else if let spec = Model.hotkeySpec(e) {
                value = spec
                note = ""
                stop()
            } else {
                note = "Control, Option or Command with a letter, digit or F1–F12"
            }
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
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
    @AppStorage("logShown") private var logShown = true

    private var downloadsJnlp: String { NSHomeDirectory() + "/Downloads/launch.jnlp" }
    private var hasDownloadsJnlp: Bool { FileManager.default.fileExists(atPath: downloadsJnlp) }
    private var logOpen: Bool { logShown && !m.log.isEmpty }

    var body: some View {
        VStack(spacing: 14) {
            // IPMIView's container running: the button opens its console (starting it again would
            // replace the container, and close IPMIView and its viewers)
            Button { m.containerRunning ? m.openBrowserConsole() : m.launch() } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        if m.launchingIPMIView {
                            ProgressView().controlSize(.small).colorScheme(.dark)      // white on the button
                                .frame(width: 18, height: 16)
                        } else {
                            Image(systemName: m.containerRunning ? "macwindow" : "play.rectangle.fill")
                                .frame(width: 18, height: 16)
                        }
                        Text(m.launchingIPMIView ? "Starting IPMIView…" : m.containerRunning ? "Open IPMIView"
                             : m.ipmiviewRunning ? "IPMIView is running" : (m.containerBusy ? "Working…" : "Launch IPMIView"))
                    }
                    .font(.headline)
                    Text(m.containerRunning ? "its console in the browser, from the container" : "with iKVM console + keyboard fixes")
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
                        if m.launchingJnlp > 0 {
                            ProgressView().controlSize(.small).frame(height: 17)
                        } else {
                            Image(systemName: "arrow.down.doc").frame(height: 17)
                        }
                        Text(m.launchingJnlp > 0 ? "Starting the .jnlp…" : "Drop a .jnlp here, or click to choose").font(.caption)
                    }.foregroundColor(dropTargeted ? .accentColor : .secondary)
                )
                .onTapGesture { if !(m.useContainer && m.containerBusy) { m.openJnlp() } }
                .onDrop(of: ["public.file-url"], isTargeted: $dropTargeted) { m.handleDrop($0) }

            Button { m.launchJnlp(downloadsJnlp) } label: {
                Label("Open Downloads/launch.jnlp", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .disabled((m.useContainer && m.containerBusy) || !hasDownloadsJnlp)
            .help(hasDownloadsJnlp ? downloadsJnlp : "No launch.jnlp in your Downloads folder")

            if m.containerRunning || !m.jnlpConsoles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if m.containerRunning {
                        HStack {
                            Text("IPMIView container").font(.caption)
                            Spacer()
                            Button("Stop", role: .destructive) { m.stopContainer() }
                                .help("Ends IPMIView and its consoles, and removes the container")
                        }
                    }
                    ForEach(m.jnlpConsoles, id: \.self) { port in
                        HStack {
                            Text(".jnlp console (port \(String(port)))").font(.caption)
                            Spacer()
                            Button("Open console") { m.openBrowser(m.consoleURL(port)) }
                            Button("Stop", role: .destructive) { m.stopJnlp(port) }
                        }
                    }
                }
            }

            if !m.log.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Button { logShown.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: logShown ? "chevron.down" : "chevron.right")
                            Text("Log")
                        }
                        .font(.caption).foregroundColor(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if logShown {
                        LogView(text: m.log)
                            .frame(minHeight: 84, maxHeight: .infinity)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)    // collapsed too: the header stays left
            }

            // (Preferences: the app menu, Cmd+,)
            HealthBadge(level: m.health.level, text: m.health.text)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            if !m.useContainer { m.checkInputMonitoring() }     // asked before any viewer starts
            m.handleLaunchArgs()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var m: Model
    private let w: CGFloat = 540

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Text("Keyboard").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Paste hotkey")
                        Spacer()
                        HotkeyField(value: $m.pasteHotkey)
                    }
                    Text("In the iKVM viewer, it types your clipboard on the remote. By the keys' places "
                         + "on a US keyboard. For viewers started afterwards; the agent's KeyPasta dialog "
                         + "(viewer: Options › KeyPasta Agent) turns it off, and swaps Alt and Command.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    if m.pasteHotkey.lowercased().contains("cmd") {
                        Text("macOS and browsers keep most Command shortcuts to themselves: they may never reach the viewer.")
                            .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox(label: Text("Mode").font(.headline)) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Accept the BMC's expired iKVM certificate", isOn: $m.disableTLS)
                    Text("Only for old BMC firmware whose KVM certificate expired. The console stays "
                         + "encrypted but the BMC's identity isn't checked, so set the BMC's clock "
                         + "back before the expiry too. Leave off with current firmware.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

                    Toggle("Run in a container", isOn: $m.useContainer)
                    Text("Runs the whole console in an amd64 Linux container, shown in your browser. "
                         + "The first run downloads a JRE and Java Web Start into the image "
                         + "automatically. Needed from macOS 28 on, when Rosetta goes away. Off: native.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

                    if m.useContainer {
                        Toggle("Open iKVM Viewer windows in separate browser tabs", isOn: $m.viewerTabs)
                        Text("Each console IPMIView opens fills a browser tab of its own (up to nine). "
                             + "Off: they open as windows next to IPMIView. Takes effect at the next start.")
                            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }

                    let rt = Model.containerRuntimes()
                    Text("Container runtimes detected: "
                         + (rt.isEmpty ? "none (install Docker, OrbStack, or Colima)" : rt.joined(separator: ", ")))
                        .font(.caption).foregroundColor(.secondary)

                    HealthBadge(level: m.health.level, text: m.health.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            if m.useContainer {
                GroupBox(label: Text("Browser").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Open the consoles in", selection: $m.browserChoice) {
                            Text("Automatic: Chrome or Edge if installed, else the default browser").tag("auto")
                            Text("Default browser" + (m.defaultBrowserName.map { " (\($0))" } ?? "")).tag("default")
                            Divider()
                            ForEach(m.browserApps, id: \.self) { app in
                                Text(Model.appName(app)).tag("app:" + app)
                            }
                            Divider()
                            Text("Select other…").tag("other")
                            Text("Command").tag("command")
                        }
                        if m.browserChoice == "command" {
                            TextField("open -a Safari \"${URL}\"", text: $m.browserCommand)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                            Text("A shell command; ${URL} is the console's address (keep it in double quotes). "
                                 + "For example Chrome, with its profile \"Profile 1\", each console in a window "
                                 + "of its own without tabs and address bar (app mode):")
                                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(Model.browserCommandExample)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("The profile's folder name is at the end of \"Profile Path\" in chrome://version.")
                                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }

            if !m.useContainer {
                GroupBox(label: Text("Keyboard LEDs").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(m.ledAccess ? "Input Monitoring: allowed" : "Input Monitoring: not allowed")
                            Spacer()
                            Button("Open Settings…") {
                                if let u = URL(string: Model.inputMonitoringPane) { NSWorkspace.shared.open(u) }
                            }
                        }
                        Text("The viewer reads your keyboard's LEDs (CapsLock) through it. Without it, the "
                             + "viewer works too, without LED sync. After an update of this app, macOS "
                             + "may need it allowed again: remove the app there and add it again.")
                            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .onAppear { m.ledAccess = m.inputMonitoringGranted }
            }

            GroupBox(label: Text("Paths").font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    PathRow(label: "IPMIView folder", value: $m.ipmiview, pickDirectory: true,
                            onDetect: { m.detectIPMIView(force: true) })
                    if m.useContainer {
                        PathRow(label: "Virtual media folder, /root/vMedia in the container (blank = none)",
                                value: $m.isoDir, pickDirectory: true)
                        PathRow(label: "Screenshots and recordings, /root/screencap in the container (blank = none)",
                                value: $m.screencapDir, pickDirectory: true)
                    }
                    if !m.useContainer {
                        PathRow(label: "Viewer Java runtime (x86_64, via Rosetta)",
                                value: $m.intelJava, pickDirectory: true,
                                onDetect: { m.detectIntelJava(force: true) })
                        PathRow(label: "OpenWebStart / javaws (to open .jnlp files)",
                                value: $m.javawsPath, pickDirectory: false,
                                onDetect: { m.detectJavaws(force: true) })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
        .padding(20)
        .frame(width: w)
        .fixedSize(horizontal: false, vertical: true)
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
        alert.messageText = "Quit IPMIView KeyPasta?"
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

@main
struct IPMIViewKeyPastaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model()
    var body: some Scene {
        // one window: no File › New Window, no tabs (Window, not WindowGroup; tabbing off)
        Window("IPMIView KeyPasta", id: "main") {
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
        }
        Settings {
            SettingsView(m: model)
        }
    }
}
