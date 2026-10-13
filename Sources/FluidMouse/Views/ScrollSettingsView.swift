import SwiftUI

struct ScrollSettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("Velocidade"); Spacer(); Text(String(format: "%.1f×", controller.speed)).monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: $controller.speed, in: 0.5...4, step: 0.1).accessibilityLabel("Velocidade")
                    HStack { Text("Suavização"); Spacer(); Text(smoothnessLabel).foregroundStyle(.secondary) }
                    Slider(value: $controller.smoothness, in: 0...1, step: 0.05).accessibilityLabel("Suavização")
                    HStack {
                        Text("Resposta rápida").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Mais deslizamento").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Toggle("Inverter direção somente do mouse", isOn: $controller.reverse)
                    Text("O trackpad mantém a rolagem nativa. Segure Option (⌥) para usar a rodinha sem suavização.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Toggle("Abrir ao iniciar sessão", isOn: Binding(get: { controller.loginEnabled || controller.loginNeedsApproval },
                            set: { controller.setLogin($0) }))
                        Spacer()
                        Button("Restaurar ajustes") { controller.reset() }.controlSize(.small)
                    }
                    if controller.loginNeedsApproval {
                        Button("Autorizar início automático nos Ajustes…") { controller.openLoginSettings() }
                    }
                }.padding(8)
            }
    }

    private var smoothnessLabel: String {
        controller.smoothness < 0.3 ? "Leve" : controller.smoothness > 0.7 ? "Alta" : "Equilibrada"
    }
}
