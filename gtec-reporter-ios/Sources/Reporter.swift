import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// The whole job: heartbeat the console, read what comes back, post it.
///
/// Two things are different from the Android reporter, and both come from
/// iOS rather than from GT7.
///
/// There is no background service. Android keeps the socket alive behind a
/// notification for twelve hours; iOS suspends an app that leaves the
/// screen. So this runs in the foreground, holds the screen awake while it
/// is reporting, and says so plainly. A driver props the phone up on a
/// charger, which is what every other telemetry app for this game asks for.
///
/// And it cannot shout. The Android reporter finds the console by
/// broadcasting to 255.255.255.255, which on iOS needs an entitlement
/// granted by Apple on application. Instead the console's address is typed
/// in once, or found by asking every address on the local network in turn,
/// which is ordinary unicast and needs nobody's permission.
@MainActor
final class Reporter: ObservableObject {

    /// GT7 sends telemetry here, and only one app per phone can hold it.
    static let stdPort: UInt16 = 33740
    /// And listens for the heartbeat here.
    private static let consolePort: UInt16 = 33739
    /// GT7 stops streaming one to two seconds after the last heartbeat.
    private static let heartbeat: TimeInterval = 1.5

    @Published private(set) var running = false
    @Published private(set) var status = "Stopped"
    @Published private(set) var packets = 0

    private var task: Task<Void, Never>?
    private var permissionProbe: NWBrowser?

    // ----------------------------------------------------------------
    /// `listenPort` and `forwardTo` exist for one case only: another
    /// telemetry app on this same phone. Only one app can hold 33740 and GT7
    /// always sends there, so the two have to agree who owns it. Either this
    /// one owns it and copies every datagram on to a local port the other is
    /// listening on, or the other owns it and this one listens for its copy.
    /// Same two settings as the desktop connector, for the same reason.
    ///
    /// An app on another device needs none of this: the console answers each
    /// device separately.
    func start(token: String, consoleIP: String,
               listenPort: UInt16 = Reporter.stdPort, forwardTo: [UInt16] = []) {
        guard !running else { return }
        running = true
        status = "Starting…"
        packets = 0
        keepAwake(true)
        askForLocalNetwork()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.loop(token: token, consoleIP: consoleIP,
                             listenPort: listenPort, forwardTo: forwardTo)
        }
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
        keepAwake(false)
        permissionProbe?.cancel()
        permissionProbe = nil
        status = "Stopped"
    }

    private func keepAwake(_ on: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    /// iOS asks the owner of the phone before letting an app talk to things
    /// on their own network, and it only asks when it recognises what the
    /// app is doing. A raw socket is not always recognised: the traffic can
    /// be dropped with no prompt and no error, which looks exactly like a
    /// console that is switched off. Starting a Bonjour browse is the
    /// documented way to raise the question properly, so one is started and
    /// immediately left running in the background doing nothing else.
    private func askForLocalNetwork() {
        let desc = NWBrowser.Descriptor.bonjour(type: "_gtec._udp", domain: nil)
        let browser = NWBrowser(for: desc, using: .udp)
        browser.start(queue: .global(qos: .utility))
        permissionProbe = browser
    }

    private func set(_ text: String) {
        Task { @MainActor in self.status = text }
    }

    private func bump() {
        Task { @MainActor in self.packets += 1 }
    }

    // ----------------------------------------------------------------
    private nonisolated func loop(token: String, consoleIP: String,
                                  listenPort: UInt16, forwardTo: [UInt16]) async {
        // A reporter that is second in the chain must not ping the console:
        // the app that owns 33740 is already doing that, and the console
        // answers whoever asked, on the port it owns.
        let weOwnThePort = listenPort == Reporter.stdPort

        guard let sock = UDP.bound(to: listenPort) else {
            // Another app on THIS phone is holding the port. Apps on other
            // devices are never the cause: the console answers each one
            // separately, so a dashboard on a PC or a tablet runs alongside
            // this quite happily.
            set(weOwnThePort
                ? "Another app on this phone is using port 33740. Close it, or "
                  + "give this one its own listen port under Sharing."
                : "Port \(listenPort) is in use. Pick another under Sharing.")
            await MainActor.run { self.running = false; self.keepAwake(false) }
            return
        }
        defer { close(sock) }

        var lastHeartbeat = Date.distantPast
        var nextBeaconAt = Date.distantPast
        var lastSeenLap = -1
        var lapStartedAt: Date?
        var seen = 0

        while !Task.isCancelled {
            let now = Date()

            if weOwnThePort, now.timeIntervalSince(lastHeartbeat) >= Reporter.heartbeat {
                // A missed heartbeat corrects itself on the next tick.
                _ = UDP.send(sock, byte: UInt8(ascii: "A"),
                             to: consoleIP, port: Reporter.consolePort)
                lastHeartbeat = now
            }

            guard let raw = UDP.receive(sock, timeout: 1.0) else {
                if seen == 0 || now.timeIntervalSince(lastHeartbeat) > 6 {
                    set(weOwnThePort
                        ? "Waiting for GT7 · is the console on the same WiFi?"
                        : "Waiting on port \(listenPort) · is the other app "
                          + "forwarding to it?")
                }
                continue
            }

            // Passed on untouched, before anything is read from it, so the
            // other app sees exactly what the console sent.
            for port in forwardTo {
                _ = UDP.send(sock, bytes: raw, to: "127.0.0.1", port: port)
            }

            guard let sample = GT7Packet.decode(raw) else { continue }

            seen += 1
            bump()

            // GT7 does not send elapsed time on the current lap, so it is
            // derived from when the lap counter last changed. Nil until a
            // lap ticks over, rather than guessing from when the app opened.
            if sample.lap != lastSeenLap {
                lastSeenLap = sample.lap
                lapStartedAt = now
            }
            let lapMs = lapStartedAt.map { Int(now.timeIntervalSince($0) * 1000) }

            if now >= nextBeaconAt {
                let reply = await Beacon.send(token: token, sample: sample, lapMs: lapMs)
                nextBeaconAt = now.addingTimeInterval(Double(reply.nextMs) / 1000)
                if !reply.ok, let err = reply.error {
                    set(err)
                } else if reply.reporting {
                    set("Reporting · lap \(sample.lap)"
                        + (sample.onTrack ? "" : " · in menus"))
                } else {
                    set("Connected to GT7 · no race on")
                }
            }
        }
    }

    // ----------------------------------------------------------------
    /// Find the console by asking every address on this network in turn.
    ///
    /// 254 unicast heartbeats, which is a few kilobytes and takes a couple
    /// of seconds. Whatever answers on the telemetry port is the console.
    /// This is what a broadcast would have done in one packet, done the
    /// long way round because the short way needs an entitlement.
    func findConsole() async -> String? {
        guard let mine = UDP.localIPv4(), let dot = mine.lastIndex(of: ".") else {
            status = "No WiFi connection to search"
            return nil
        }
        guard let sock = UDP.bound(to: Reporter.stdPort) else {
            // The search has to listen on 33740, because that is where the
            // console will answer, so it cannot run while another app on this
            // phone holds it. The address can still be typed in by hand.
            status = "Another app on this phone is using port 33740. "
                + "Close it, or type the address in."
            return nil
        }
        defer { close(sock) }

        askForLocalNetwork()
        status = "Looking for your console…"
        let prefix = String(mine[..<dot])

        for round in 0..<2 {
            for host in 1...254 {
                _ = UDP.send(sock, byte: UInt8(ascii: "A"),
                             to: "\(prefix).\(host)", port: Reporter.consolePort)
                // A short pause every so often, so a burst of 254 packets
                // does not simply overrun the phone's send buffer.
                if host % 32 == 0 { try? await Task.sleep(nanoseconds: 60_000_000) }
            }
            // GT7 answers within a second or so of being asked.
            let deadline = Date().addingTimeInterval(round == 0 ? 1.5 : 3.0)
            while Date() < deadline {
                if let (raw, from) = UDP.receiveFrom(sock, timeout: 0.5),
                   GT7Packet.decode(raw) != nil {
                    status = "Found your console at \(from)"
                    return from
                }
            }
        }
        status = "No console answered · check it is on and on this WiFi"
        return nil
    }
}
