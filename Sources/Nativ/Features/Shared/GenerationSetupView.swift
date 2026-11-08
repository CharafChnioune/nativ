import NativServerKit
import SwiftUI

struct GenerationSetupView: View {
    @ObservedObject var library: GenerationLibraryObserver
    let model: NativModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var connections = GenerationConnectionProfiles.shared
    @State private var remoteName = ""
    @State private var remoteURL = ""
    @State private var remoteKey = ""
    @State private var privateHTTP = false
    @State private var addingServer = false
    @State private var selectedID = ""
    @State private var enabled = false
    @State private var experimentalEnabled = false
    @State private var licenseAccepted = false
    @State private var accountEligible = false
    @State private var separateLicenseApproved = false
    @State private var region = "global"
    @State private var endpoint = ""
    @State private var accountID = ""
    @State private var secret = ""
    @State private var status: String?
    @State private var busy = false
    @State private var runtimes: [String: GenerationJSONValue] = [:]
    private var profile: GenerationProfile? { library.profiles.first { $0.id == selectedID } }
    private var client: NativGenerationClient? { library.connection.map { NativGenerationClient(modality: library.modality, connection: $0) } }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("\(library.modality.rawValue.capitalized) providers and runtimes").font(.title2.weight(.semibold))
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Nativ server", selection: Binding(get: { connections.selectedID }, set: { id in
                do { try connections.select(id) } catch { status = error.localizedDescription }
            })) { ForEach(connections.profiles) { Text($0.name).tag($0.id) } }
            DisclosureGroup("Connect a remote Nativ server", isExpanded: $addingServer) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $remoteName)
                    TextField("https://your-nativ-server", text: $remoteURL)
                    SecureField("Nativ server API key", text: $remoteKey)
                    Toggle("Allow HTTP to a private development address", isOn: $privateHTTP).font(.caption)
                    Button("Save and connect") {
                        do { try connections.add(name: remoteName, url: remoteURL, apiKey: remoteKey, allowPrivateHTTP: privateHTTP); remoteKey = ""; addingServer = false }
                        catch { status = error.localizedDescription }
                    }
                }.padding(.top, 8)
            }
            if library.connection == nil {
                Text("Start Nativ's server and configure its API key in Developer settings. Generation endpoints require authentication.")
            }
            Picker("Profile", selection: $selectedID) {
                Text("Choose a profile").tag("")
                ForEach(library.profiles) { profile in Text("\(profile.displayName) · \(profile.deploymentLabel)").tag(profile.id) }
            }
            if let profile {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(profile.readinessLabel) · \(profile.qualification)").font(.headline)
                    if let reason = profile.unavailableReason { Text(reason).foregroundStyle(.secondary) }
                    Text("Model: \(profile.model)\nProfile revision: \(profile.profileRevision)").font(.caption).textSelection(.enabled)
                    if let attribution = profile.attribution { Text(attribution).font(.caption) }
                    Toggle("Enable this profile", isOn: $enabled)
                    if profile.qualification != "qualified" {
                        Toggle("Enable this unqualified profile for deliberate testing", isOn: $experimentalEnabled)
                    }
                    if profile.deployment == "local" {
                        Toggle("I have reviewed and accept the model and component licenses", isOn: $licenseAccepted)
                        if profile.provider == "minimax_h3_mlx" {
                            Text("MiniMax H3's default weight license excludes the EU, UK, Republic of Korea and USA. A public download does not grant eligibility.").font(.caption).foregroundStyle(.orange)
                            Toggle("I have a separate license approving this deployment", isOn: $separateLicenseApproved)
                        }
                        Link("Review runtime and model licenses", destination: URL(string: profile.provider == "acestep" ? "https://github.com/ace-step/ACE-Step-1.5" : profile.provider == "minimax_h3_mlx" ? "https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE" : profile.provider == "stable_audio_mlx" ? "https://stability.ai/license" : profile.provider == "ltx_mlx" ? "https://github.com/Lightricks/LTX-2" : "https://huggingface.co/" + profile.model)!)
                    }
                    if profile.provider == "minimax_cloud" {
                        Text("New paid Music API access ended on August 20, 2026. This adapter is for existing eligible accounts.").font(.caption).foregroundStyle(.secondary)
                        Toggle("My existing account is eligible for MiniMax Music", isOn: $accountEligible)
                        Picker("Account region", selection: $region) { Text("Global").tag("global"); Text("China").tag("china") }
                    }
                    if profile.deployment != "local" {
                        if let retention = profile.capabilities["provider_storage"]?.stringValue {
                            Text(retention).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Anyone with your Nativ server API key can use enabled providers. Pricing and eligibility follow your configured provider account. No generation is performed by connection checks.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Account identity (required for safe recovery)", text: $accountID)
                        if profile.deployment == "remote_gpu" { TextField("HTTPS endpoint", text: $endpoint) }
                        if connections.selected.kind == .localEmbedded { SecureField("Provider API key · saved in this Mac's Keychain", text: $secret) }
                        Text("Saving a key requires restarting the embedded server before use. For a remote canonical Nativ server, configure the provider key on that server.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Save configuration") { Task { await save() } }.disabled(busy || client == nil)
                        if profile.deployment == "local" {
                            Button("Install") { Task { await runtimeAction("install") } }.disabled(busy)
                            Button("Repair") { Task { await runtimeAction("repair") } }.disabled(busy)
                            Button("Cancel installation") { Task { await runtimeAction("cancel-install") } }.disabled(busy)
                            Button("Remove runtime") { Task { await runtimeAction("remove") } }.disabled(busy)
                        }
                    }
                    if profile.deployment == "local" {
                        Text("Installation uses the server's pinned component manifest and checks disk capacity and integrity. Weights and gated licenses require your deliberate approval; an unqualified profile stays unavailable until its hardware and license checks pass.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if let status { Text(status).font(.callout).textSelection(.enabled) }
            if let items = runtimes["items"]?.arrayValue {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    if let values = item.objectValue, selectedID.isEmpty || values["profile_id"]?.stringValue == selectedID {
                        GenerationRuntimeStatusRow(values: values)
                    }
                }
            }
            HStack {
                Button("Reconnect") { library.reconnect() }
                Button("Refresh readiness") { Task { await library.refresh(); await load() } }
                Spacer()
                Text("Discovery never loads models or starts paid work.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder).padding(24)
        }
        .frame(width: 620, height: 720)
        .task {
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: library.storeID) { _, _ in selectedID = "" }
        .task(id: selectedID) { await loadConfiguration() }
    }
    private func load() async {
        do { runtimes = try await client?.runtimes() ?? [:] } catch { status = error.localizedDescription }
    }
    private func loadConfiguration() async {
        secret = ""; accountID = ""; endpoint = ""; enabled = false; experimentalEnabled = false; licenseAccepted = false; accountEligible = false; separateLicenseApproved = false; region = "global"
        guard let client, !selectedID.isEmpty else { return }
        let selected = selectedID
        do {
            let configurations = try await client.configuration()
            guard selectedID == selected, !Task.isCancelled else { return }
            let values = configurations[selectedID]?.objectValue ?? configurations["profiles"]?.objectValue?[selectedID]?.objectValue ?? [:]
            experimentalEnabled = values["experimental_enabled"]?.boolValue ?? false; licenseAccepted = values["license_accepted"]?.boolValue ?? false; accountEligible = values["account_eligible"]?.boolValue ?? false; separateLicenseApproved = values["separate_license_approved"]?.boolValue ?? false; region = values["region"]?.stringValue ?? "global"
            enabled = values["enabled"]?.boolValue ?? false; endpoint = values["endpoint"]?.stringValue ?? ""; accountID = values["account_id"]?.stringValue ?? ""
        } catch { status = error.localizedDescription }
    }
    private func save() async {
        guard let client, let profile else { return }
        busy = true; defer { busy = false }
        do {
            var values: [String: GenerationJSONValue] = ["enabled": .bool(enabled)]
            if profile.qualification != "qualified" { values["experimental_enabled"] = .bool(experimentalEnabled) }
            if profile.deployment == "local" {
                values["license_accepted"] = .bool(licenseAccepted)
                if profile.provider == "minimax_h3_mlx" { values["separate_license_approved"] = .bool(separateLicenseApproved) }
            }
            if profile.provider == "minimax_cloud" { values["account_eligible"] = .bool(accountEligible); values["region"] = .string(region) }
            if profile.deployment != "local" {
                values["account_id"] = .string(accountID)
                if profile.deployment == "remote_gpu" { values["endpoint"] = .string(endpoint) }
                if !secret.isEmpty {
                    try GenerationProviderCredentials().save(secret, profileID: profile.id)
                    secret = ""
                }
            }
            _ = try await client.updateConfiguration(profileID: profile.id, values: values)
            status = "Configuration saved. Restart the embedded server if its provider key changed."
            await library.refresh()
        } catch { status = error.localizedDescription }
    }
    private func runtimeAction(_ action: String) async {
        guard let client, let profile else { return }
        busy = true; defer { busy = false }
        do {
            // Runtime identity comes from the immutable server catalogue, never user input.
            guard let id = profile.runtime else {
                status = "The server did not provide a managed runtime for this profile."; return
            }
            _ = try await client.runtimeAction(id: id, action: action, profileID: profile.id)
            await load(); await library.refresh()
        } catch { status = error.localizedDescription }
    }
}


private struct GenerationRuntimeStatusRow: View {
    let values: [String: GenerationJSONValue]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(values["profile_id"]?.stringValue ?? "Runtime").font(.caption.weight(.semibold))
                Spacer()
                Text((values["status"]?.stringValue ?? "unknown").replacingOccurrences(of: "_", with: " ").capitalized).font(.caption)
            }
            if let stage = values["stage"]?.stringValue { Text(stage.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption).foregroundStyle(.secondary) }
            if let progress = values["progress"]?.numberValue, progress.isFinite, (0...1).contains(progress) { ProgressView(value: progress) }
            if let bytes = values["required_model_bytes"]?.numberValue {
                Text("Model components: " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).font(.caption)
            }
            if let error = values["error"]?.objectValue?["message"]?.stringValue { Text(error).font(.caption).foregroundStyle(.orange) }
            DisclosureGroup("Components and licenses") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array((values["components"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, component in
                        if let component = component.objectValue {
                            HStack {
                                Text(component["name"]?.stringValue ?? component["path"]?.stringValue ?? "Component").lineLimit(2)
                                Spacer()
                                if let bytes = component["bytes"]?.numberValue { Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
                            }
                        }
                    }
                    ForEach(Array((values["licenses"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, license in
                        if let name = license.stringValue { Text(name) }
                        else if let license = license.objectValue { Text(license["name"]?.stringValue ?? license["id"]?.stringValue ?? "Review the pinned component license") }
                    }
                }.font(.caption).padding(.top, 5)
            }.font(.caption)
        }
        .padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
