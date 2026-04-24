import SwiftUI

struct TokenStatsButton: View {
    @ObservedObject private var statsManager = TokenStatisticsManager.shared
    @State private var isHovered = false
    @ObservedObject var viewModel: NotchViewModel
    
    var body: some View {
        Button {
            AppDelegate.shared?.showSettingsWindow(section: .tokenUsage)
            viewModel.notchClose()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))

                Text("\(statsManager.formatTokens(statsManager.globalStats.totalTokens)) tk")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: statsManager.globalStats.totalTokens)
            }
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct TokenStatisticsView: View {
    @ObservedObject private var statsManager = TokenStatisticsManager.shared
    @ObservedObject var viewModel: NotchViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Button {
                    viewModel.showInstances()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(6)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                
                Text("Global Token Usage")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Button {
                    Task {
                        await statsManager.rebuildHistoryFromDisk()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if statsManager.isRebuildingHistory {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white.opacity(0.8))
                        }

                        Text(statsManager.isRebuildingHistory ? "Scanning…" : "Rebuild")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(statsManager.isRebuildingHistory ? 0.16 : 0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(statsManager.isRebuildingHistory)
                
            }
            .padding(.horizontal, 4)
            
            // Total usage summary
            VStack(spacing: 8) {
                Text(statsManager.globalStats.totalTokens.formatted())
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: statsManager.globalStats.totalTokens)
                
                Text("imported history + live usage")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.vertical, 8)

            if statsManager.isRebuildingHistory {
                Text("Scanning historical sessions and rebuilding totals…")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // Breakdown by agent
            VStack(alignment: .leading, spacing: 12) {
                Text("By Agent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .textCase(.uppercase)
                
                if statsManager.globalStats.byAgent.isEmpty {
                    Text("No tokens used yet")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 4)
                } else {
                    let total = max(1, statsManager.globalStats.totalTokens)
                    
                    ForEach(statsManager.globalStats.byAgent.sorted(by: { $0.value.totalTokens > $1.value.totalTokens }), id: \.key) { agent, stats in
                        VStack(spacing: 6) {
                            HStack {
                                Text(agent)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                Text("\(statsManager.formatTokens(stats.totalTokens)) tk")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            
                            // Progress bar
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.white.opacity(0.1))
                                        .frame(height: 6)
                                    
                                    let width = geometry.size.width * CGFloat(stats.totalTokens) / CGFloat(total)
                                    
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(agentColor(for: agent))
                                        .frame(width: max(0, width), height: 6)
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)
            
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }
    
    private func agentColor(for agent: String) -> Color {
        if agent == "Claude Code" {
            return Color(red: 0.85, green: 0.47, blue: 0.34) // Claude orange
        } else if agent == "Coco" {
            return Color(red: 0.35, green: 0.6, blue: 0.95) // Coco blue
        } else {
            return Color.white.opacity(0.6)
        }
    }
}
