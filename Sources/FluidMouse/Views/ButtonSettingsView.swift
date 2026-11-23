import SwiftUI
import FluidMouseCore

/// Row level editing for global button remapping.
struct ButtonSettingsView: View {
    @ObservedObject var controller: AppController
    @State private var expandedButton: Int?
    /// Numbers reported by press-to-identify that are not in the standard list.
    @State private var extraButtons: Set<Int> = []
    @State private var confirmClearAll = false

    /// Keycodes of the standard ANSI layout. Letters are omitted because their
    /// physical roles shift between keyboard layouts.
    static let keys: [(code: Int, name: String)] = [
        (36, "Return"), (49, "Espaço"), (48, "Tab"), (53, "Esc"),
        (51, "Delete"), (117, "Apagar avançar"),
        (123, "Seta ←"), (124, "Seta →"), (125, "Seta ↓"), (126, "Seta ↑"),
        (115, "Home"), (119, "End"), (116, "Page Up"), (121, "Page Down"),
        (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"),
        (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12")
    ]

    static let buttonTitles: [(number: Int, title: String)] = [
        (0, "Esquerdo"), (1, "Direito"), (2, "Meio"),
        (3, "Extra 1"), (4, "Extra 2"), (5, "Extra 3"),
        (6, "Extra 4"), (7, "Extra 5"), (8, "Extra 6")
    ]

    static let modifierSymbols: [KeystrokeModifier: String] = [
        .command: "⌘", .option: "⌥", .control: "⌃", .shift: "⇧"
    ]

    static let modifierNames: [KeystrokeModifier: String] = [
        .command: "Command", .option: "Option", .control: "Control", .shift: "Shift"
    ]

    /// Title for a button number; numbers past the standard list continue the
    /// "Extra" sequence (no hardware limit is assumed).
    static func title(for number: Int) -> String {
        if let known = buttonTitles.first(where: { $0.number == number }) { return known.title }
        return "Extra \(number - 2)"
    }

    /// Standard buttons plus every number that has a mapping or was captured.
    static func rowNumbers(mappings: [Int: ButtonAction], captured: Set<Int>) -> [Int] {
        Set(buttonTitles.map(\.number)).union(mappings.keys).union(captured).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.sectionSpacing) {
                SectionHeader(symbol: "cursorarrow.rays",
                              title: "Remapeamento de botões",
                              subtitle: "Cada botão pode disparar outra ação no lugar do uso original. As funções valem para todos os mice (remapeamento global por botão).")
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 12) {
                    deviceHeader
                    if controller.awaitingButtonPress {
                        HStack(spacing: 10) {
                            Image(systemName: "scope").foregroundStyle(Design.accent)
                            Text("Aperte o botão físico que você quer configurar…")
                                .font(.callout).fontWeight(.medium)
                            Spacer()
                            Text("Esc")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Cancelar") { controller.cancelButtonCapture() }
                                .controlSize(.small)
                                .keyboardShortcut(.cancelAction)
                        }
                        .padding(10)
                        .background(Design.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(spacing: 4) {
                        ForEach(Self.rowNumbers(mappings: controller.buttonMappings, captured: extraButtons),
                                id: \.self) { number in
                            row(button: number, title: Self.title(for: number))
                        }
                    }
                    .disabled(controller.awaitingButtonPress)
                    Text("Cada botão aciona a ação escolhida no lugar do seu uso original. Remapear os botões esquerdo ou direito afeta clique e arraste; use com cautela.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Ações de sistema seguem os atalhos padrão do macOS; atalhos personalizados não são seguidos. Brilho afeta apenas a tela integrada.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        if !controller.buttonMappings.isEmpty {
                            Button("Limpar tudo") { confirmClearAll = true }
                                .controlSize(.small)
                                .disabled(controller.awaitingButtonPress)
                                .confirmationDialog("Limpar todos os remapeamentos?",
                                                    isPresented: $confirmClearAll,
                                                    titleVisibility: .visible) {
                                    Button("Limpar tudo", role: .destructive) { controller.clearButtonMappings() }
                                    Button("Cancelar", role: .cancel) {}
                                } message: {
                                    Text("Cada botão volta ao uso original do mouse.")
                                }
                        }
                    }
                }
                .card()
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: controller.capturedButton) { button in
            guard let button else { return }
            extraButtons.insert(button)
            expandedButton = button
            capturedAcknowledged()
        }
        .onDisappear {
            // Sair da aba não deixa a captura armada: o próximo clique do mouse
            // seria engolido por uma tela que já não está visível.
            if controller.awaitingButtonPress { controller.cancelButtonCapture() }
        }
    }

    @ViewBuilder private var deviceHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.detectedDevices.isEmpty ? "computermouse" : "computermouse.fill")
                .foregroundStyle(controller.detectedDevices.isEmpty ? Color.secondary : Design.accent)
            if controller.detectedDevices.isEmpty {
                Text("Nenhum mouse reconhecido ainda")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.detectedDevices.count == 1 ? "Mouse reconhecido" :
                            "\(controller.detectedDevices.count) mice reconhecidos")
                        .font(.caption).fontWeight(.semibold)
                    Text(controller.detectedDevices.map(\.display).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button(controller.awaitingButtonPress ? "Aguardando clique…" : "Identificar botão") {
                controller.beginButtonCapture()
            }
            .controlSize(.small)
            .disabled(controller.awaitingButtonPress)
        }
    }

    private func capturedAcknowledged() {
        // The view only reads it once; clear so future captures can fire onChange again.
        controller.clearCapturedButton()
    }

    @ViewBuilder private func row(button: Int, title: String) -> some View {
        let action = controller.buttonMappings[button] ?? .unchanged
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(title).frame(width: 64, alignment: .leading)
                Menu {
                    menuContent(button: button)
                } label: {
                    HStack {
                        Text(Self.summary(of: action))
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.frame(width: 170, alignment: .leading)
                }
                .accessibilityLabel("Ação do botão \(title)")
                .accessibilityValue(Self.summary(of: action))
                Spacer()
                Button {
                    controller.beginButtonCapture()
                } label: {
                    Image(systemName: "scope")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(controller.awaitingButtonPress)
                .help("Aperte um botão no mouse para configurá-lo aqui")
                .accessibilityLabel("Identificar \(title) pressionando o botão físico")
            }
            if button == expandedButton, case .key(let combination)? = controller.buttonMappings[button] {
                keyEditor(button: button, combination: combination)
            }
        }
        .padding(.vertical, 3)
        .background(button == expandedButton ? Design.accent.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private func menuContent(button: Int) -> some View {
        Section("Básico") {
            Button("Sem alteração") { controller.buttonMappings[button] = .unchanged }
            Button("Desativar") { controller.buttonMappings[button] = .disabled }
        }
        Section("Clique") {
            Button("Clique esquerdo") { controller.buttonMappings[button] = .click(button: 0) }
            Button("Clique direito") { controller.buttonMappings[button] = .click(button: 1) }
            Button("Clique do meio") { controller.buttonMappings[button] = .click(button: 2) }
        }
        Section("Rolagem") {
            Button("Rolagem suave ↑") { controller.buttonMappings[button] = .scroll(.up) }
            Button("Rolagem suave ↓") { controller.buttonMappings[button] = .scroll(.down) }
        }
        Section("Sistema") {
            ForEach(SystemAction.allCases, id: \.self) { action in
                Button(Self.summary(of: .system(action))) {
                    controller.buttonMappings[button] = .system(action)
                }
            }
        }
        Section("Teclado") {
            Button("Tecla e modificadores…") {
                expandedButton = button
                controller.buttonMappings[button] = .key(KeyCombination(keycode: 49))
            }
        }
    }

    private func keyEditor(button: Int, combination: KeyCombination) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach([KeystrokeModifier.command, .option, .control, .shift], id: \.self) { modifier in
                    Toggle(isOn: Binding(
                        get: { combination.modifiers.contains(modifier) },
                        set: { on in
                            var modifiers = combination.modifiers
                            if on { modifiers.insert(modifier) } else { modifiers.remove(modifier) }
                            controller.buttonMappings[button] = .key(KeyCombination(
                                keycode: combination.keycode, modifiers: modifiers,
                                behavior: combination.behavior))
                        })) {
                        Text(Self.modifierSymbols[modifier] ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel(Self.modifierNames[modifier] ?? "")
                    .help(Self.modifierNames[modifier] ?? "")
                }
                Picker("Tecla", selection: Binding(
                    get: { combination.keycode },
                    set: { controller.buttonMappings[button] = .key(KeyCombination(
                        keycode: $0, modifiers: combination.modifiers,
                        behavior: combination.behavior)) })) {
                    ForEach(Self.keys, id: \.code) { key in
                        Text(key.name).tag(key.code)
                    }
                }.labelsHidden().frame(width: 150)
                Spacer()
            }
            .padding(.leading, 64)
            Picker("Comportamento", selection: Binding(
                get: { combination.effectiveBehavior },
                set: { controller.buttonMappings[button] = .key(KeyCombination(
                    keycode: combination.keycode, modifiers: combination.modifiers,
                    behavior: $0)) })) {
                Text("Apertar e soltar").tag(KeyBehavior.tap)
                Text("Ficar pressionado").tag(KeyBehavior.hold)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .padding(.leading, 64)
            .labelsHidden()
        }
    }

    static func summary(of action: ButtonAction) -> String {
        switch action {
        case .unchanged: return "Sem alteração"
        case .disabled: return "Desativado"
        case .scroll(.up): return "Rolagem suave ↑"
        case .scroll(.down): return "Rolagem suave ↓"
        case .click(0): return "Clique esquerdo"
        case .click(1): return "Clique direito"
        case .click(2): return "Clique do meio"
        case .click(let button): return "Clique (botão \(button))"
        case .key(let k):
            let prefix = KeystrokeModifier.allCases
                .filter { k.modifiers.contains($0) }
                .compactMap { modifierSymbols[$0] }.joined()
            let name = keys.first { $0.code == k.keycode }?.name ?? "\(k.keycode)"
            let body = "Tecla \(prefix)\(name)"
            return k.effectiveBehavior == .hold ? "\(body) (enquanto segura)" : body
        case .system(let s): return systemName(s)
        }
    }

    private static func systemName(_ action: SystemAction) -> String {
        switch action {
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Mostrar área de trabalho"
        case .spotlight: return "Spotlight"
        case .launchpad: return "Launchpad"
        case .spaceLeft: return "Espaço à esquerda"
        case .spaceRight: return "Espaço à direita"
        case .volumeUp: return "Aumentar volume"
        case .volumeDown: return "Diminuir volume"
        case .mute: return "Mudo"
        case .playPause: return "Reproduzir / Pausar"
        case .nextTrack: return "Próxima faixa"
        case .previousTrack: return "Faixa anterior"
        case .brightnessUp: return "Aumentar brilho"
        case .brightnessDown: return "Diminuir brilho"
        }
    }
}
