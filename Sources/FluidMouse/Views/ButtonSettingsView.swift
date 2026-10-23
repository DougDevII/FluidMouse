import SwiftUI
import FluidMouseCore

/// Row level editing for global button remapping.
struct ButtonSettingsView: View {
    @ObservedObject var controller: AppController
    @State private var expandedButton: Int?

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

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                deviceHeader
                if controller.awaitingButtonPress {
                    HStack(spacing: 10) {
                        Image(systemName: "scope").foregroundStyle(.teal)
                        Text("Aperte o botão que você quer configurar no seu mouse…")
                            .font(.callout).fontWeight(.medium)
                        Spacer()
                        Button("Cancelar") { controller.cancelButtonCapture() }
                            .controlSize(.small)
                    }
                    .padding(10)
                    .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Self.buttonTitles, id: \.number) { button in
                            row(button: button.number, title: button.title)
                        }
                    }
                }
                .frame(maxHeight: 240)
                Text("Cada botão aciona a ação escolhida no lugar do seu uso original. Remapear os botões esquerdo ou direito afeta clique e arraste; use com cautela.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if !controller.buttonMappings.isEmpty {
                        Button("Limpar tudo") { controller.clearButtonMappings() }.controlSize(.small)
                    }
                }
            }.padding(8)
        }
        .onChange(of: controller.capturedButton) { button in
            guard let button else { return }
            expandedButton = button
            capturedAcknowledged()
        }
    }

    @ViewBuilder private var deviceHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.detectedDevices.isEmpty ? "computermouse" : "computermouse.fill")
                .foregroundStyle(controller.detectedDevices.isEmpty ? Color.secondary : .teal)
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
            }
            if button == expandedButton, case .key(let combination)? = controller.buttonMappings[button] {
                keyEditor(button: button, combination: combination)
            }
        }
        .padding(.vertical, 3)
        .background(button == expandedButton ? Color.teal.opacity(0.10) : Color.clear,
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
                }
                Picker("", selection: Binding(
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
