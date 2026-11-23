import SwiftUI

/// Janela principal do FluidMouse: barra lateral no padrão do macOS
/// (como Ajustes do Sistema) e o conteúdo da seção escolhida à direita.
struct ContentView: View {
    @ObservedObject var controller: AppController
    @State private var section: Section = .ajustes

    /// Comando do menu "Ir Para" (atalhos ⌘1–4 como itens reais de menu,
    /// expostos na barra de menus enquanto o app está ativo).
    static let selectSectionCommand = Notification.Name("br.com.douglas.fluido.select-section")

    enum Section: String, CaseIterable, Identifiable {
        case ajustes, botoes, mouse, teste

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ajustes: return "Ajustes"
            case .botoes: return "Botões"
            case .mouse: return "Mouse"
            case .teste: return "Teste"
            }
        }

        var symbol: String {
            switch self {
            case .ajustes: return "slider.horizontal.3"
            case .botoes: return "cursorarrow.rays"
            case .mouse: return "computermouse"
            case .teste: return "waveform.path.ecg"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 196, ideal: 210, max: 240)
        } detail: {
            detail
        }
        .navigationTitle("FluidMouse")
        .frame(minWidth: 720, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: Self.selectSectionCommand)) { note in
            guard let index = note.object as? Int,
                  Section.allCases.indices.contains(index) else { return }
            section = Section.allCases[index]
        }
    }

    // MARK: Sidebar

    /// Linhas soltas no `List` — uma por aba, `Label` + `tag`, no padrão
    /// HIG "Sidebars" (um ícone, um título; badges como detalhe secundário).
    /// A seleção vem do próprio `List` (clique é teclado ↑/↓); ⌘1–4 chegam
    /// pelas ações de menu reais (App → "Ir Para"), que publicam
    /// `selectSectionCommand`.
    private var sidebar: some View {
        List(selection: $section) {
            ForEach(Section.allCases) { item in
                HStack {
                    Label(item.title, systemImage: item.symbol)
                    Spacer(minLength: 8)
                    badge(for: item)
                }
                .tag(item)
                .accessibilityElement(children: .combine)
            }
        }
        .listStyle(.sidebar)
    }

    /// Selo na lateral: nível da bateria do mouse e estado da rolagem.
    @ViewBuilder private func badge(for item: Section) -> some View {
        switch item {
        case .mouse:
            if let percent = controller.rapooStatus?.percent {
                StatusChip(text: "\(percent)%", symbol: nil, tint: .secondary)
            }
        case .ajustes:
            if controller.enabled {
                StatusChip(text: "ativo", symbol: "checkmark", tint: .green)
            }
        case .botoes:
            if !controller.buttonMappings.isEmpty {
                StatusChip(text: "\(controller.buttonMappings.count)", symbol: nil, tint: .secondary)
            }
        case .teste:
            EmptyView()
        }
    }

    // MARK: Detail

    @ViewBuilder private var selectedView: some View {
        switch section {
        case .ajustes:
            ScrollSettingsView(controller: controller)
        case .botoes:
            ButtonSettingsView(controller: controller)
        case .mouse:
            RapooHardwareView(controller: controller)
        case .teste:
            ScrollTestView(controller: controller)
        }
    }

    /// Estados globais no topo de QUALQUER aba: erro (banner dispensável) e
    /// permissão de Acessibilidade (cartão persistente até conceder). Ambos
    /// consomem `AppController` diretamente, sem estado duplicado.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.errorMessage != nil {
                ErrorBanner(controller: controller)
                    .padding([.horizontal, .top], 20)
            }
            if !controller.trusted {
                PermissionCard(controller: controller)
                    .padding([.horizontal, .top], 20)
            }
            selectedView
        }
    }
}
