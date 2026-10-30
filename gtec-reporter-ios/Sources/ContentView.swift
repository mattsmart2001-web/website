import SwiftUI

/// The whole interface: a code, a console, a button, and the truth about
/// what is happening.
///
/// Everything here is the same shape as the Android app, with one addition
/// it does not need: the console's address. Android finds it by shouting;
/// iOS has to be told, or go and look.
struct ContentView: View {
    @StateObject private var reporter = Reporter()
    @AppStorage("token") private var token = ""
    @AppStorage("consoleIP") private var consoleIP = ""
    @AppStorage("listenPort") private var listenPort = ""
    @AppStorage("forwardTo") private var forwardTo = ""
    @State private var searching = false

    /// Blank, unreadable or out of range all mean the standard port, rather
    /// than refusing to start over a typo in a setting almost nobody touches.
    private var port: UInt16 {
        UInt16(listenPort.trimmingCharacters(in: .whitespaces)) ?? Reporter.stdPort
    }

    private var forwardPorts: [UInt16] {
        forwardTo.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The console's address only matters when this app is the one pinging it.
    /// Second in the chain, the data arrives from the app that owns the port.
    private var ready: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty
            && (!consoleIP.isEmpty || port != Reporter.stdPort)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pairing code", text: $token)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .disabled(reporter.running)
                } header: {
                    Text("Your code")
                } footer: {
                    Text("From your GTEC portal, under Account. It is what tells the "
                         + "timing board which car is yours.")
                }

                Section {
                    HStack {
                        TextField("192.168.1.x", text: $consoleIP)
                            .keyboardType(.decimalPad)
                            .disabled(reporter.running || searching)
                        Button(searching ? "Looking…" : "Find it") {
                            Task {
                                searching = true
                                if let found = await reporter.findConsole() { consoleIP = found }
                                searching = false
                            }
                        }
                        .disabled(reporter.running || searching)
                    }
                } header: {
                    Text("Your console")
                } footer: {
                    Text("On the PlayStation: Settings, Network, Connection Status. "
                         + "Or tap Find it and this will ask every device on your WiFi "
                         + "until one answers.")
                }

                Section {
                    Button(reporter.running ? "Stop reporting" : "Start reporting") {
                        if reporter.running {
                            reporter.stop()
                        } else {
                            reporter.start(token: token.trimmingCharacters(in: .whitespaces),
                                           consoleIP: consoleIP,
                                           listenPort: port,
                                           forwardTo: forwardPorts)
                        }
                    }
                    .disabled(!ready && !reporter.running)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(reporter.running ? .red : .accentColor)
                }

                Section {
                    Label(reporter.status, systemImage: icon)
                        .font(.callout)
                    if reporter.packets > 0 {
                        Text("\(reporter.packets) packets from the console")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Status")
                } footer: {
                    if reporter.running {
                        Text("Leave this on screen. iPhone stops an app that is not in "
                             + "front of you, so switching away or locking the phone ends "
                             + "the session. The screen is held awake while this is "
                             + "running, so put it on a charger for a long race.")
                    }
                }

                Section {
                    TextField("33740", text: $listenPort)
                        .keyboardType(.numberPad)
                        .disabled(reporter.running)
                    TextField("Copy to, e.g. 33741", text: $forwardTo)
                        .keyboardType(.numbersAndPunctuation)
                        .disabled(reporter.running)
                } header: {
                    Text("Sharing with another app")
                } footer: {
                    Text("Leave both empty unless you run another telemetry app on this "
                         + "same phone. An app on another device is never a problem: the "
                         + "console answers each device separately.\n\n"
                         + "Only one app per phone can hold port 33740, and GT7 always "
                         + "sends there, so the two have to agree. Either let this one "
                         + "own it and copy the data on, or let the other own it and "
                         + "listen here for its copy.")
                }
            }
            .navigationTitle("GTEC Live Timing")
        }
    }

    private var icon: String {
        if !reporter.running { return "pause.circle" }
        if reporter.status.hasPrefix("Reporting") { return "dot.radiowaves.left.and.right" }
        if reporter.status.hasPrefix("Waiting") { return "magnifyingglass" }
        return "exclamationmark.triangle"
    }
}
