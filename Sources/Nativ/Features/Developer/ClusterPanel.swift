import SwiftUI

/// Status a Nativ cluster node reports at `GET /v1/cluster/status`.
struct ClusterNodeStatus: Decodable, Equatable {
    let state: String
    let capacityBytes: Int64
    let versions: [String: ClusterVersionValue]

    enum CodingKeys: String, CodingKey {
        case state, versions
        case capacityBytes = "capacity_bytes"
    }
}

/// Version entries are strings except the protocol number.
enum ClusterVersionValue: Decodable, Equatable, CustomStringConvertible {
    case number(Int), text(String)
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self = .number(value) } else { self = .text(try container.decode(String.self)) }
    }
    var description: String {
        switch self {
        case .number(let value): "\(value)"
        case .text(let value): value
        }
    }
}

enum ClusterNodeClient {
    static func status(of node: String, apiKey: String?) async throws -> ClusterNodeStatus {
        guard let url = URL(string: node + "/v1/cluster/status") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 5)
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            throw NSError(domain: "Cluster", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: http.statusCode == 404
                ? "Cluster node is off on that Mac" : "HTTP \(http.statusCode)"])
        }
        return try JSONDecoder().decode(ClusterNodeStatus.self, from: data)
    }
}

/// Developer card: let other Macs run layers of this Mac's chat model, or offer this Mac to a host.
struct ClusterPanel: View {
    @Binding var settings: NativSettings
    @State private var newNode = ""
    @State private var statuses: [String: Result<ClusterNodeStatus, Error>] = [:]

    private var normalized: NativSettings { settings.normalized() }
    private var hostIsLoopback: Bool { ["127.0.0.1", "localhost", "::1"].contains(normalized.serverHost) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Cluster", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                Spacer()
                Button("Refresh") { Task { await refresh() } }
                    .disabled(normalized.clusterNodeURLs.isEmpty)
            }
            Text("Run one chat model across several Macs over Tailscale (plain LAN addresses are refused: cluster traffic is unencrypted). Every Mac needs this same Nativ build and the same server API token.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Accept model layers from other Macs (node)", isOn: $settings.clusterNodeEnabled)
            if settings.clusterNodeEnabled {
                if normalized.serverAPIKey == nil {
                    warning("Set a server API token first; nodes refuse work without one.")
                }
                if hostIsLoopback {
                    warning("Set Host to 0.0.0.0 or this Mac's Tailscale address so other Macs can reach it.")
                }
            }

            Divider()
            Text("Nodes for this Mac's chat model").font(.subheadline.weight(.medium))
            ForEach(normalized.clusterNodeURLs, id: \.self) { node in
                HStack {
                    Text(node).font(.callout.monospaced())
                    Spacer()
                    statusText(for: node)
                    Button(role: .destructive) {
                        settings.clusterNodeURLs.removeAll { $0 == node }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(node)")
                }
            }
            HStack {
                TextField("http://100.x.y.z:8080", text: $newNode)
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                    .onSubmit(addNode)
                Button("Add", action: addNode)
                    .disabled(NativSettings.normalizedClusterNodeURLs([newNode]).isEmpty)
            }
            if normalized.clusterHostActive {
                Text("This Mac is the host: its chat model loads split across these nodes by free memory. Cluster mode serves one request at a time without prefix caching, KV quantization or draft models. Supported families include DeepSeek, GLM, Kimi and Ministral 3.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .task(id: normalized.clusterNodeURLs) { await refresh() }
    }

    private func addNode() {
        guard let node = NativSettings.normalizedClusterNodeURLs([newNode]).first else { return }
        if !settings.clusterNodeURLs.contains(node) { settings.clusterNodeURLs.append(node) }
        newNode = ""
    }

    private func refresh() async {
        let apiKey = normalized.serverAPIKey
        for node in normalized.clusterNodeURLs {
            do { statuses[node] = .success(try await ClusterNodeClient.status(of: node, apiKey: apiKey)) }
            catch { statuses[node] = .failure(error) }
        }
    }

    @ViewBuilder private func statusText(for node: String) -> some View {
        switch statuses[node] {
        case .success(let status)?:
            Text("\(status.state) · \(ByteCountFormatter.string(fromByteCount: status.capacityBytes, countStyle: .memory)) free")
                .font(.caption).foregroundStyle(.secondary)
        case .failure(let error)?:
            Text(error.localizedDescription).font(.caption).foregroundStyle(.red).lineLimit(1)
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
    }
}
