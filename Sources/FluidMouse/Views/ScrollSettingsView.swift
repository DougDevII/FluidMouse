import SwiftUI

/// Ajustes da rolagem suave: velocidade, suavização, direção e início automático.
struct ScrollSettingsView: View {
    @ObservedObject var controller: AppController
    @State private var speedDraft = ""
    @State private var speedRejected = false
    @State private var confirmReset = false
    @FocusState private var speedFocused: Bool

    static let speedRange: ClosedRange<Double> = 0.5...4

    /// Valor digitado válido: finito, dentro de 0,5–4 e arredondado ao passo de 0,1.
    static func parseSpeed(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, speedRange.contains(value) else { return nil }
        return (value * 10).rounded() / 10
    }

    /// Valor confirmado ao sair do campo: texto inválido mantém o valor atual.
    static func commitSpeed(_ text: String, current: Double) -> Double {
        parseSpeed(text) ?? current
    }

    static func formatSpeed(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.sectionSpacing) {
                // A permissão de Acessibilidade virou componente global
                // (UI-01): o cartão aparece uma vez, no topo de qualquer aba,
                // montado em ContentView — não mais aqui.

                SectionHeader(symbol: "slider.horizontal.3",
                              title: "Rolagem suave",
                              subtitle: "A rodinha passa a deslizar em vez de pular.")
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $controller.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ativar/Pausar suavização")
                            Text(controller.status)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Ativar ou pausar suavização")

                    Divider()

                    speedRow

                    sliderRow(title: "Suavização",
                              value: smoothnessLabel,
                              binding: $controller.smoothness,
                              range: 0...1, step: 0.05)

                    HStack {
                        Text("Resposta rápida").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Mais deslizamento").font(.caption).foregroundStyle(.secondary)
                    }

                    Divider()

                    Toggle(isOn: $controller.reverse) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Inverter direção somente do mouse")
                            Text("O trackpad mantém a rolagem nativa.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Inverter direção somente do mouse")
                }
                .card()

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(symbol: "power", title: "Inicialização e atalhos")
                    Toggle(isOn: Binding(
                        get: { controller.loginEnabled || controller.loginNeedsApproval },
                        set: { controller.setLogin($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Abrir ao iniciar sessão")
                            Text("O FluidMouse entra sozinho quando você faz login.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Abrir ao iniciar sessão")
                    if controller.loginNeedsApproval {
                        HStack {
                            StatusChip(text: "Aguardando autorização", symbol: "exclamationmark.triangle",
                                       tint: .orange)
                            Button("Abrir Ajustes…") { controller.openLoginSettings() }
                                .controlSize(.small)
                        }
                    }
                    HStack {
                        Text("Segure Option (⌥) para usar a rodinha sem suavização.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restaurar ajustes") { confirmReset = true }
                            .controlSize(.small)
                            .confirmationDialog("Restaurar ajustes de rolagem?",
                                                isPresented: $confirmReset,
                                                titleVisibility: .visible) {
                                Button("Restaurar", role: .destructive) { controller.reset() }
                                Button("Cancelar", role: .cancel) {}
                            } message: {
                                Text("Velocidade, suavização e direção voltam aos valores padrão.")
                            }
                    }
                }
                .card()
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { commitSpeedDraft() }
    }

    private var speedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Velocidade").font(.system(size: 13, weight: .medium))
                Spacer()
                TextField("", text: $speedDraft)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .accessibilityLabel("Velocidade exata")
                    .focused($speedFocused)
                    .onSubmit { commitSpeedDraft() }
                Text("×")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $controller.speed, in: Self.speedRange, step: 0.1)
                .accessibilityLabel("Velocidade")
                .accessibilityValue(String(format: "%.1f×", controller.speed))
            if speedRejected {
                Text("Digite um valor entre 0,5× e 4×. O valor anterior foi mantido.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { speedDraft = Self.formatSpeed(controller.speed) }
        .onChange(of: speedFocused) { focused in
            if !focused { commitSpeedDraft() }
        }
        .onChange(of: controller.speed) { value in
            speedDraft = Self.formatSpeed(value)
            speedRejected = false
        }
    }

    /// Confirma o rascunho (Enter ou perda de foco). Só aqui o valor é aplicado;
    /// o texto é sempre normalizado a partir do valor confirmado.
    private func commitSpeedDraft() {
        speedRejected = Self.parseSpeed(speedDraft) == nil
        let next = Self.commitSpeed(speedDraft, current: controller.speed)
        if next != controller.speed { controller.speed = next }
        speedDraft = Self.formatSpeed(controller.speed)
    }

    private func sliderRow(title: String, value: String, binding: Binding<Double>,
                            range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
    }

    private var smoothnessLabel: String {
        controller.smoothness < 0.3 ? "Leve" : controller.smoothness > 0.7 ? "Alta" : "Equilibrada"
    }
}
