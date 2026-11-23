import SwiftUI

/// Settings → Fleet: turn it on, pair Macs, and choose what each may do here.
struct FleetSettingsSection: View {
    @ObservedObject var fleet: FleetMonitor
    @AppStorage(MachineIdentity.nameKey) private var machineName = ""
    @AppStorage(FleetStore.allowLANKey) private var allowLAN = false

    @State private var pairAddress = ""
    @State private var pairCode = ""
    @State private var pairing = false
    @State private var pairError: String?
    @State private var pairedMessage: String?
    @State private var showManual = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { fleet.isEnabled }, set: { fleet.setEnabled($0) })) {
                Text("Connect your Macs")
                Text("See each other's load, agents and records over Tailscale")
            }

            if fleet.isEnabled {
                LabeledContent("This Mac") {
                    TextField("Name", text: $machineName, prompt: Text(MachineIdentity.defaultName))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                LabeledContent {
                    Text("Port \(String(fleet.store.port))").foregroundStyle(.secondary)
                } label: {
                    Text(MachineIdentity.current().hardwareSummary)
                    if let error = fleet.serverError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("Fleet")
        } footer: {
            if !fleet.isEnabled {
                Text("Off: Cracked makes no network connections except to Ollama on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if fleet.isEnabled {
            pairedSection
            pairSection
        }
    }

    // MARK: - Paired Macs

    @ViewBuilder
    private var pairedSection: some View {
        if !fleet.peers.isEmpty {
            Section {
                ForEach(fleet.peers) { peer in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: peer.machine.formFactor.symbol)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(peer.name)
                                Text(status(peer))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { fleet.remove(peer) }
                                .controlSize(.small)
                        }
                        Toggle("Can unload local models on this Mac", isOn: Binding(
                            get: { peer.allowUnloadModels },
                            set: { fleet.setPermission(peer, unloadModels: $0) }))
                            .controlSize(.small)
                        Toggle("Can restart or snooze apps on this Mac", isOn: Binding(
                            get: { peer.allowRestartApps },
                            set: { fleet.setPermission(peer, restartApps: $0) }))
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Paired Macs")
            } footer: {
                Text("Restarts only work on apps already listed under Worth a Restart on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ peer: FleetPeer) -> String {
        let hardware = peer.machine.hardwareSummary
        guard let state = fleet.states[peer.id] else { return hardware }
        if state.isOnline() { return hardware + " · online" }
        if let seen = state.lastSeen { return hardware + " · last seen \(AgentRowView.age(of: seen)) ago" }
        return hardware + " · offline"
    }

    // MARK: - Pairing

    private var pairSection: some View {
        Section {
            // Showing a code: this Mac is the one being added.
            if let code = fleet.pairingCode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Enter this code on your other Mac:")
                    Text(code.prefix(3) + " " + code.suffix(3))
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    if let expiry = fleet.pairingExpiry {
                        Text("Expires \(expiry, style: .relative). Works for one Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Done") { fleet.closePairing() }
                        .controlSize(.small)
                }
                .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                    fleet.checkPairingCode()
                }
            } else {
                LabeledContent {
                    Button("Show Code") { fleet.openPairing() }
                        .controlSize(.small)
                } label: {
                    Text("Add this Mac to another")
                    Text("Shows a code to type on the other Mac")
                }
            }

            // Entering a code: pairing with a Mac on the tailnet.
            ForEach(fleet.unpairedCandidates) { candidate in
                LabeledContent {
                    Button(pairAddress == candidate.address ? "Cancel" : "Pair…") {
                        pairAddress = pairAddress == candidate.address ? "" : candidate.address
                        pairError = nil
                        pairCode = ""
                    }
                    .controlSize(.small)
                    .disabled(!candidate.online)
                } label: {
                    Text(candidate.hostName)
                    Text(candidate.online ? candidate.address : "offline on Tailscale")
                }
                if pairAddress == candidate.address { codeEntry }
            }

            DisclosureGroup("Pair by address", isExpanded: $showManual) {
                TextField("Address", text: $pairAddress, prompt: Text("100.x.y.z or name.ts.net"))
                    .textFieldStyle(.roundedBorder)
                if !pairAddress.isEmpty && !fleet.unpairedCandidates.contains(where: { $0.address == pairAddress }) {
                    codeEntry
                }
            }

            if let pairedMessage {
                Label(pairedMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Toggle(isOn: $allowLAN) {
                Text("Also accept connections from my local network")
                Text("Tailscale encrypts fleet traffic; your LAN doesn't. Leave this off unless a Mac isn't on Tailscale.")
            }
            .onChange(of: allowLAN) { _, _ in fleet.restartServer() }
        } header: {
            HStack {
                Text("Pair a Mac")
                Spacer()
                Button {
                    fleet.refreshCandidates()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Look for Macs on Tailscale again")
            }
        } footer: {
            Text(TailscalePeers.cliPath == nil
                 ? "Tailscale isn't installed, so Cracked can't list your Macs. Pair by address instead."
                 : "Both Macs need Cracked open with Fleet turned on. On the Mac you're adding, click Show Code.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("6-digit code", text: $pairCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 140)
                    .onSubmit(pair)
                if pairing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Pair", action: pair)
                        .disabled(pairCode.filter(\.isNumber).count != 6)
                }
            }
            if let pairError {
                Text(pairError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pair() {
        let address = pairAddress
        let code = pairCode
        pairing = true
        pairError = nil
        pairedMessage = nil
        Task {
            do {
                let peer = try await fleet.pair(address: address, port: FleetStore.defaultPort, code: code)
                pairedMessage = "Paired with \(peer.name)"
                pairAddress = ""
                pairCode = ""
            } catch {
                pairError = error.localizedDescription
            }
            pairing = false
        }
    }
}
