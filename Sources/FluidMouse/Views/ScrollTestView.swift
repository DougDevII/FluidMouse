import SwiftUI

/// Estado da captura de rolagem, derivado de flags tipadas (nunca do texto de
/// `controller.status`). Usado pela área de teste e pelo menu de status.
enum ScrollCaptureState: CaseIterable, Equatable {
    case paused
    case needsAccessibility
    case smoothyRunning
    case active
    case inactive

    static func from(enabled: Bool, trusted: Bool, smoothyRunning: Bool, running: Bool) -> ScrollCaptureState {
        if !enabled { return .paused }
        if !trusted { return .needsAccessibility }
        if smoothyRunning { return .smoothyRunning }
        return running ? .active : .inactive
    }

    /// Curto o bastante para um item de menu (HIG: até 30 caracteres).
    var title: String {
        switch self {
        case .paused: return "Suavização pausada"
        case .needsAccessibility: return "Aguardando Acessibilidade"
        case .smoothyRunning: return "Feche o Smoothy para ativar"
        case .active: return "Rolagem suave ativa"
        case .inactive: return "Sem captura da rolagem"
        }
    }

    var symbol: String {
        switch self {
        case .paused: return "pause.circle"
        case .needsAccessibility: return "hand.raised"
        case .smoothyRunning: return "exclamationmark.triangle"
        case .active: return "checkmark.circle.fill"
        case .inactive: return "exclamationmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .active: return .green
        case .paused: return .secondary
        case .needsAccessibility, .smoothyRunning, .inactive: return .orange
        }
    }
}

/// Área de teste: uma lista para rolar com a rodinha e comparar o
/// comportamento com o FluidMouse ligado e desligado.
struct ScrollTestView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.sectionSpacing) {
                SectionHeader(symbol: "waveform.path.ecg",
                              title: "Teste de rolagem",
                              subtitle: "Role com a rodinha sobre a lista e compare a suavização.")
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 10) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(1...60, id: \.self) { index in
                                HStack(spacing: 14) {
                                    Text(String(format: "%02d", index))
                                        .monospacedDigit().foregroundStyle(.secondary)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Design.accent.opacity(Double(index % 5 + 1) / 7))
                                        .frame(width: CGFloat(80 + index % 7 * 38), height: 6)
                                    Spacer()
                                    Text("Rolagem suave").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14).frame(height: 38)
                                Divider()
                            }
                        }
                    }
                    .frame(height: 260)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 12) {
                        let state = ScrollCaptureState.from(enabled: controller.enabled,
                                                            trusted: controller.trusted,
                                                            smoothyRunning: controller.smoothyRunning,
                                                            running: controller.running)
                        StatusChip(text: state.title, symbol: state.symbol, tint: state.tint)
                        Spacer()
                        Text("Segure Option (⌥) para comparar com a rolagem nativa.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(symbol: "waveform", title: "Diagnóstico",
                                  subtitle: "Contadores locais da captura de eventos.")
                    SummaryRow(label: "Eventos de rodinha", value: "\(controller.wheelCount)")
                    SummaryRow(label: "Contínuos preservados", value: "\(controller.trackpadCount)")
                    SummaryRow(label: "Frames gerados", value: "\(controller.frameCount)")
                    Text("Processamento 100% local · sem conta e sem mensalidade.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .card()
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
