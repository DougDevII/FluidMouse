import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: AppController
    @State private var diagnostics = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "computermouse.fill").font(.system(size: 32)).foregroundStyle(.teal)
                    .frame(width: 62, height: 62).background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 17))
                VStack(alignment: .leading, spacing: 4) {
                    Text("FluidMouse").font(.system(size: 28, weight: .bold))
                    Text("Uma rolagem mais leve para o seu mouse.").foregroundStyle(.secondary)
                }
                Spacer()
                Text("GRATUITO").font(.caption.bold()).foregroundStyle(.secondary)
            }
            HStack {
                Circle().fill(controller.running ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(controller.status).fontWeight(.medium)
                Spacer()
                Toggle("Ativar", isOn: $controller.enabled).toggleStyle(.switch).fixedSize()
            }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            if !controller.trusted {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Permita suavizar a rolagem").fontWeight(.semibold)
                        Text("Em Ajustes do Sistema → Privacidade e Segurança → Acessibilidade, ative o FluidMouse. A suavização começará automaticamente.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Abrir Acessibilidade…") { controller.grantPermission() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            if controller.smoothyRunning {
                Label("Encerre o Smoothy pelo menu dele para testar o FluidMouse sem interferência.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            TabView {
                ScrollSettingsView(controller: controller)
                    .padding(12).tabItem { Text("Ajustes") }
                ButtonSettingsView(controller: controller)
                    .padding(12).tabItem { Text("Botões") }
                VStack(alignment: .leading, spacing: 18) {
                    ScrollTestView()
                    Text("Compare a rodinha com o trackpad. Inverta a direção rapidamente: a animação anterior deve parar. Segure Option (⌥) para comparar com a rolagem original.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.padding(18).tabItem { Text("Teste de rolagem") }
            }.frame(height: 462)
            DisclosureGroup("Diagnóstico", isExpanded: $diagnostics) {
                HStack(spacing: 18) {
                    Text("Rodinha: \(controller.wheelCount)")
                    Text("Contínuos preservados: \(controller.trackpadCount)")
                    Text("Frames: \(controller.frameCount)")
                }.font(.caption).monospacedDigit().foregroundStyle(.secondary).padding(.top, 6)
            }
            HStack {
                Text("100% local · Sem mensalidade · Código aberto").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        }
        .frame(width: 580, height: 885)
        .alert("Ajuste não concluído", isPresented: Binding(get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } })) {
                Button("OK") { controller.errorMessage = nil }
            } message: { Text(controller.errorMessage ?? "") }
    }

}
