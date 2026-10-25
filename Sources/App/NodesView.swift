import SwiftUI

struct NodesView: View {
    @EnvironmentObject var app: AppState
    @State private var paste = ""
    @State private importMsg = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextEditor(text: $paste)
                        .frame(minHeight: 90)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        app.addImport(text: paste)
                        paste = ""
                    } label: {
                        Label("导入节点", systemImage: "plus.circle.fill")
                            .font(.headline)
                    }
                    .foregroundStyle(.cyan)
                    if !importMsg.isEmpty {
                        Text(importMsg).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("粘贴分享链接（每行一条，支持 vless / vmess / ss）")
                        .font(.caption)
                }

                Section("节点列表（\(app.nodes.count)）") {
                    ForEach(app.nodes) { n in
                        NodeRow(node: n,
                                isDefault: app.defaultNodeID == n.id,
                                latency: app.nodeLatency[n.id])
                            .swipeActions {
                                Button(role: .destructive) {
                                    app.remove(n.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    app.setDefault(n.id)
                                } label: {
                                    Label("默认", systemImage: "star")
                                }
                                .tint(.yellow)
                            }
                        .contentShape(Rectangle())
                        .onTapGesture { app.setDefault(n.id) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("节点管理")
            .toolbar {
                Button("测速") {
                    if let n = app.currentNode { app.testNode(n) }
                }
                .disabled(app.nodes.isEmpty)
                .foregroundStyle(.cyan)
            }
        }
        .onAppear { importMsg = app.toast ?? "" }
    }
}

struct NodeRow: View {
    let node: ProxyNode
    let isDefault: Bool
    let latency: Double?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.name).lineLimit(1)
                    if isDefault {
                        Text("★").font(.caption).foregroundStyle(.yellow)
                    }
                }
                Text("\(node.proto) · \(node.host):\(node.port) · \(node.network)")
                    .font(.caption2).foregroundStyle(.gray).lineLimit(1)
            }
            Spacer()
            if let ms = latency {
                Text(String(format: "%.0f ms", ms))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.cyan)
            }
        }
        .padding(.vertical, 4)
    }
}
