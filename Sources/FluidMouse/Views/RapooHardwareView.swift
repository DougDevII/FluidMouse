import SwiftUI
import FluidMouseCore

/// Configuração de hardware do mouse Rapoo VT9 Pro: tudo o que o mouse
/// guarda no próprio register map, falado pelo `RapooHidService`. O modelo
/// de registradores é fixo (`RapooProtocol`): toda alteração é um
/// read-modify-write de um bloco inteiro, nunca uma escrita parcial.
///
/// Cada controle que grava mostra o progresso da própria operação (por id) e
/// fica desabilitado enquanto ela está pendente. Nada é pré-aplicado: o valor
/// exibido é sempre o último lido do mouse. A tabela de DPI é um rascunho
/// separado (`controller.rapooDpiDraft`) que só vira leitura confirmada após o
/// callback de sucesso da própria gravação.
struct RapooHardwareView: View {
    @ObservedObject var controller: AppController

    private let pollingRates = [125, 250, 500, 1000, 2000, 4000]
    private let sleepOptions = [1, 5, 10, 15, 30, 60, 120]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.sectionSpacing) {
                if let status = controller.rapooStatus {
                    if status.permissionPending {
                        permissionPendingCard(status: status)
                    } else {
                        content(status: status)
                    }
                } else {
                    missingDevice
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func isPending(_ id: String) -> Bool {
        controller.rapooOperations[id]?.outcome == .pending
    }

    // MARK: Cabeçalho

    private func pageHeader(title: String, subtitle: String, symbol: String,
                            busy: Bool = false, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Design.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let action {
                if busy { ProgressView().controlSize(.small) }
                Button("Atualizar", action: action)
                    .controlSize(.small)
                    .disabled(busy)
            }
        }
    }

    // MARK: Estados

    @ViewBuilder private func permissionPendingCard(status: RapooHidService.Status) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Permita configurar o mouse")
                        .font(.system(size: 14, weight: .semibold))
                    Text("O VT9 Pro foi detectado\(status.productID.map { " (PID \(String(format: "0x%04X", $0)))" } ?? ""), mas o macOS bloqueou o acesso ao canal de configuração dele. Em Ajustes do Sistema → Privacidade e Segurança → Monitoramento de Entrada, ative o FluidMouse e clique em Tentar novamente.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Abrir Monitoramento de Entrada…") {
                            controller.openRapooPermissionSettings()
                        }.controlSize(.small)
                        Button("Tentar novamente") { controller.refreshRapoo() }
                            .controlSize(.small)
                            .disabled(controller.rapooRefreshing)
                        if controller.rapooRefreshing {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .card(tint: Color.orange.opacity(0.10))
    }

    private var missingDevice: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "computermouse")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Nenhum Rapoo VT9 Pro conectado")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("Conecte o mouse pelo cabo USB ou pareie o receptor 2.4 GHz. O canal de configuração dele aparece aqui automaticamente.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    @ViewBuilder private func content(status: RapooHidService.Status) -> some View {
        pageHeader(title: "Rapoo VT9 Pro",
                   subtitle: "Configuração gravada no próprio mouse.",
                   symbol: "computermouse",
                   busy: controller.rapooRefreshing,
                   action: { controller.refreshRapoo() })

        statusCard(status: status)
        dpiCard(status: status)

        if status.readable {
            pollingCard(status: status)
            sensorCard(status: status)
            timingCard(status: status)
        } else {
            sleepingCard
        }

        diagnosticsPanel(status: status)
    }

    // MARK: Cartões

    @ViewBuilder private func statusCard(status: RapooHidService.Status) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(symbol: "bolt.batteryblock",
                          title: "Estado",
                          subtitle: "Energia e conexão do mouse.")
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: batterySymbol(percent: status.percent, charging: status.charging == true))
                    .font(.system(size: 26))
                    .foregroundStyle(status.percent == nil ? Color.secondary : Design.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.percent.map { "Bateria \($0)%" } ?? "Bateria indisponível")
                        .font(.system(size: 17, weight: .semibold))
                    HStack(spacing: 6) {
                        if status.charging == true {
                            StatusChip(text: "carregando", symbol: "bolt.fill", tint: .green)
                        }
                        StatusChip(text: linkText(status),
                                   symbol: status.link == .receiver ? "antenna.radiowaves.left.and.right" : "cable.connector",
                                   tint: .secondary)
                        if let pid = status.productID {
                            StatusChip(text: String(format: "PID 0x%04X", pid), symbol: nil, tint: .secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            Divider()
            if let table = status.dpi, let stage = status.activeStage, stage < table.stages.count {
                let scale = max(status.dpiScale, 1)
                SummaryRow(label: "DPI do estágio ativo", value: "\(table.stages[stage] * scale)")
            }
            SummaryRow(label: "Polling em uso",
                       value: RapooPollingReadout.activeHz(link: status.link,
                                                           receiverHz: status.receiverHz,
                                                           wiredHz: status.wiredHz)
                           .map { "\($0) Hz" } ?? "—")
        }
        .card()
    }

    private var sleepingCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Configuração dormente").font(.system(size: 13, weight: .semibold))
                Text("O firmware do VT9 Pro só responde comandos quando o mouse está em movimento. Mexa nele por 2 ou 3 segundos e a leitura volta sozinha.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    @ViewBuilder private func dpiCard(status: RapooHidService.Status) -> some View {
        let confirmed = RapooDpiDraft.confirmed(status.dpi, scale: status.dpiScale)
        let draft = controller.rapooDpiDraft
        let shown = RapooDpiDraft.displayed(draft: draft, confirmed: confirmed)
        let dirty = RapooDpiDraft.isDirty(draft: draft, confirmed: confirmed)
        let busy = isPending("rapoo.dpi")
        let problem = dirty ? shown?.problem(scale: status.dpiScale) : nil
        let unconfirmed = controller.rapooOperations["rapoo.dpi"]?.outcome.isUnconfirmed == true

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(symbol: "target",
                          title: "Estágios de DPI",
                          subtitle: "Sete estágios, um valor por estágio. Os eixos X e Y estão vinculados nesta integração.")
            if let shown {
                VStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { slot in
                        dpiRow(slot: slot, shown: shown, confirmed: confirmed, status: status)
                    }
                }
                .disabled(busy)
                Divider()
                settingRow("Estágio ativo", operation: "rapoo.stage") {
                    Picker("Estágio ativo", selection: Binding(
                        get: { status.activeStage ?? -1 },
                        set: { if $0 >= 0 { controller.setRapooActiveStage($0) } })) {
                        if status.activeStage == nil { Text("—").tag(-1) }
                        ForEach(0..<max(2, status.dpi?.enabledStages ?? 2), id: \.self) { stage in
                            Text("Estágio \(stage + 1)").tag(stage)
                        }
                    }.labelsHidden().frame(width: 170)
                }
                settingRow("Estágios habilitados") {
                    Picker("Estágios habilitados", selection: Binding(
                        get: { shown.enabledStages },
                        set: { value in editDpi(shown) { $0.enabledStages = value } })) {
                        ForEach(RapooDpiDraft.enabledRange, id: \.self) { Text("\($0)").tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 170)
                }
                .disabled(busy)

                if dirty {
                    StatusChip(text: "Alterações não aplicadas", symbol: "pencil", tint: .orange)
                }
                if let problem {
                    Text(problem)
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if unconfirmed {
                    HStack(spacing: 8) {
                        NotAppliedChip(operations: controller.rapooOperations, id: "rapoo.dpi")
                        Text("A gravação não foi confirmada pelo mouse e pode ter ficado parcial. Suas alterações continuam aqui.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Reler do mouse") { controller.refreshRapoo() }
                            .controlSize(.small)
                            .disabled(controller.rapooRefreshing)
                    }
                }
                HStack {
                    Text("Valores de 100 a 26.000 DPI. Com escala 50 só o bloco X é gravado; com escala 1, X e Y recebem a mesma tabela.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    PendingMarker(operations: controller.rapooOperations, id: "rapoo.dpi")
                    Button("Descartar") { controller.rapooDpiDraft = nil }
                        .controlSize(.small)
                        .disabled(!dirty || busy)
                    Button("Aplicar DPI") { controller.setRapooDpi(shown.stages, enabledStages: shown.enabledStages) }
                        .controlSize(.small)
                        .disabled(!dirty || problem != nil || busy)
                }
            } else {
                Text("Sem leitura de DPI ainda — conecte o mouse e mexa nele para acordar o canal.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    @ViewBuilder private func dpiRow(slot: Int, shown: RapooDpiDraft, confirmed: RapooDpiDraft?,
                                     status: RapooHidService.Status) -> some View {
        let active = status.activeStage == slot
        let current = confirmed.flatMap { $0.stages.indices.contains(slot) ? $0.stages[slot] : nil }
        HStack(spacing: 10) {
            Circle()
                .fill(active ? Design.accent : Color.clear)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(active ? Design.accent : Color.secondary.opacity(0.5),
                                              lineWidth: 1))
            Text("Estágio \(slot + 1)")
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .frame(width: 72, alignment: .leading)
            TextField("DPI", value: Binding(
                get: { shown.stages.indices.contains(slot) ? shown.stages[slot] : 0 },
                set: { value in editDpi(shown) { $0.setStage(slot, to: value) } }),
                format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 110)
                .accessibilityLabel("DPI do estágio \(slot + 1)")
            Spacer(minLength: 8)
            Text(current.map { "no mouse: \($0) DPI" } ?? "sem leitura")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func pollingCard(status: RapooHidService.Status) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(symbol: "speedometer",
                          title: "Polling rate",
                          subtitle: "Taxa de leitura do mouse — separada para receptor e cabo.")
            StatusChip(text: "experimental", symbol: "flask", tint: .orange)
            settingRow("Receptor 2.4 GHz", operation: "rapoo.polling.receiver") {
                Picker("Polling do receptor 2.4 GHz", selection: Binding(
                    get: { status.receiverHz ?? -1 },
                    set: { hz in if hz > 0 { controller.setRapooPolling(hz, onReceiver: true) } })) {
                    if status.receiverHz == nil { Text("—").tag(-1) }
                    ForEach(pollingRates, id: \.self) { hz in Text("\(hz) Hz").tag(hz) }
                }.labelsHidden().frame(width: 170)
            }
            settingRow("Cabo USB", operation: "rapoo.polling.cable") {
                Picker("Polling do cabo USB", selection: Binding(
                    get: { status.wiredHz ?? -1 },
                    set: { hz in if hz > 0 { controller.setRapooPolling(hz, onReceiver: false) } })) {
                    if status.wiredHz == nil { Text("—").tag(-1) }
                    ForEach(pollingRates, id: \.self) { hz in Text("\(hz) Hz").tag(hz) }
                }.labelsHidden().frame(width: 170)
            }
            Text("O mouse guarda um valor para cada link; trocar o cabo não apaga o do receptor.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("O layout de polling foi medido em um firmware, então trate esta aba como experimental. 8000 Hz não é oferecido: a compatibilidade física com este mouse não foi verificada.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    @ViewBuilder private func sensorCard(status: RapooHidService.Status) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(symbol: "sensor.tag.radiowaves.forward",
                          title: "Sensor",
                          subtitle: "Lift-off (altura de levantar) e correção de movimento.")
            settingRow("Lift-off", operation: "rapoo.liftoff") {
                Picker("Lift-off (código)", selection: Binding(
                    get: { status.liftoffCode ?? -1 },
                    set: { code in if code >= 0 { controller.setRapooLiftOff(code) } })) {
                    if status.liftoffCode == nil { Text("—").tag(-1) }
                    ForEach(0...3, id: \.self) { Text("Código \($0)").tag($0) }
                }.labelsHidden().frame(width: 170)
            }
            toggleRow("Motion sync", value: status.motionSync, operation: "rapoo.motionSync") {
                controller.setRapooMotionSync($0)
            }
            if let angle = status.sensorAngle, angle != 0, angle < 180 {
                SummaryRow(label: "Ângulo do sensor", value: "\(angle)°")
            }
            Text("O app oficial guarda o lift-off como código sem escala publicada (0–3); as alturas ficam entre 0,7 mm e 2,0 mm a depender do lote.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    /// Índice de debounce válido (0…6) ou −1 quando o firmware não define o
    /// valor (0xFF).
    private static func validIndex(_ index: Int?) -> Int {
        guard let index, index >= 0, index < RapooProtocol.debounceTimesMs.count else { return -1 }
        return index
    }

    /// Opções de repouso: as padrão, mais o valor lido do mouse quando ele
    /// não está na lista (para não exibir um valor trocado).
    private func sleepChoices(current: Int?) -> [Int] {
        guard let current, !sleepOptions.contains(current) else { return sleepOptions }
        return (sleepOptions + [current]).sorted()
    }

    @ViewBuilder private func timingCard(status: RapooHidService.Status) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(symbol: "timer",
                          title: "Timing",
                          subtitle: "Debounce, repouso e suavização do traço.")
            settingRow("Debounce (apertar)", operation: "rapoo.debounce") {
                Picker("Debounce (apertar)", selection: Binding(
                    get: { Self.validIndex(status.timing?.pressDebounceIndex) },
                    set: { idx in
                        guard idx >= 0 else { return }
                        controller.setRapooDebounce(pressIndex: idx, releaseIndex: nil)
                    })) {
                    Text("—").tag(-1)
                    ForEach(Array(RapooProtocol.debounceTimesMs.enumerated()), id: \.offset) { index, ms in
                        Text("\(ms) ms").tag(index)
                    }
                }.labelsHidden().frame(width: 170)
            }
            settingRow("Debounce (soltar)", operation: "rapoo.debounce") {
                Picker("Debounce (soltar)", selection: Binding(
                    get: { Self.validIndex(status.timing?.releaseDebounceIndex) },
                    set: { idx in
                        guard idx >= 0 else { return }
                        controller.setRapooDebounce(pressIndex: nil, releaseIndex: idx)
                    })) {
                    // O firmware pode deixar o debounce de soltura sem valor
                    // (0xFF) — nesse caso o campo aparece como "—".
                    Text("—").tag(-1)
                    ForEach(Array(RapooProtocol.debounceTimesMs.enumerated()), id: \.offset) { index, ms in
                        Text("\(ms) ms").tag(index)
                    }
                }.labelsHidden().frame(width: 170)
            }
            settingRow("Repouso após", operation: "rapoo.sleep") {
                Picker("Repouso após", selection: Binding(
                    get: { status.timing?.sleepMinutes ?? -1 },
                    set: { minutes in if minutes > 0 { controller.setRapooSleep(minutes) } })) {
                    if status.timing?.sleepMinutes == nil { Text("—").tag(-1) }
                    ForEach(sleepChoices(current: status.timing?.sleepMinutes), id: \.self) {
                        Text("\($0) min").tag($0)
                    }
                }.labelsHidden().frame(width: 170)
            }
            if let sleep = status.timing?.sleepMinutes, sleep <= 1 {
                Label("Com \(sleep) minuto o mouse dorme quase assim que você para de usá-lo. 5 ou 10 minutos é mais confortável.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            toggleRow("Angle snapping", value: status.timing?.angleSnapping, operation: "rapoo.angleSnap") {
                controller.setRapooAngleSnap($0)
            }
            toggleRow("Ripple control", value: status.timing?.rippleControl, operation: "rapoo.ripple") {
                controller.setRapooRipple($0)
            }
        }
        .card()
    }

    @ViewBuilder private func diagnosticsPanel(status: RapooHidService.Status) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Blocos brutos da última varredura do register map — na escala em que o firmware guarda.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(RapooHardwareView.rawRows, id: \.address) { row in
                        HStack(alignment: .top, spacing: 10) {
                            Text(row.label)
                                .font(.system(size: 11))
                                .frame(width: 140, alignment: .leading)
                                .foregroundStyle(.secondary)
                            let block = status.rawBlocks[row.address] ?? []
                            Text(block.isEmpty ? "—" : block.map { String(format: "%02x", $0) }.joined(separator: " "))
                                .font(.system(size: 11).monospacedDigit())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 1)
                    }
                    SummaryRow(label: "PID do device", value: status.productID.map { String(format: "0x%04X", $0) } ?? "—")
                }
                .padding(.top, 6)
            } label: {
                Text("Diagnóstico")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .card()
    }

    // MARK: Auxiliares

    /// Linha de ajuste no padrão das preferências do macOS: rótulo à esquerda,
    /// controle à direita. Com `operation`, mostra o progresso e o selo de
    /// "Não confirmado" dessa operação e bloqueia o controle enquanto pendente.
    private func settingRow<Control: View>(_ title: String, operation: String? = nil,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
            if let operation {
                PendingMarker(operations: controller.rapooOperations, id: operation)
                NotAppliedChip(operations: controller.rapooOperations, id: operation)
            }
            Spacer(minLength: 8)
            control()
                .disabled(operation.map { isPending($0) } ?? false)
        }
    }

    /// Liga/desliga de um valor lido do mouse. Valor ausente vira "—", sem
    /// assumir um padrão.
    @ViewBuilder private func toggleRow(_ title: String, value: Bool?, operation: String,
                                        onChange: @escaping (Bool) -> Void) -> some View {
        settingRow(title, operation: operation) {
            if let value {
                Toggle(title, isOn: Binding(get: { value }, set: onChange))
                    .labelsHidden()
                    .fixedSize()
            } else {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func batterySymbol(percent: Int?, charging: Bool) -> String {
        guard let percent else { return "battery.slash" }
        if charging { return "battery.100.bolt" }
        switch percent {
        case ..<10: return "battery.5"
        case ..<35: return "battery.25"
        case ..<60: return "battery.50"
        default: return "battery.100"
        }
    }

    private func linkText(_ status: RapooHidService.Status) -> String {
        status.linkDescription ?? "Link desconhecido"
    }

    /// Altera o rascunho de DPI a partir da base mostrada (rascunho ou leitura).
    private func editDpi(_ base: RapooDpiDraft, _ change: (inout RapooDpiDraft) -> Void) {
        var next = base
        change(&next)
        controller.rapooDpiDraft = next
    }

    static let rawRows: [(address: Int, label: String)] = [
        (0x880, "Polling (0x880)"),
        (0x884, "Sensor (0x884)"),
        (0x888, "DPI X (0x888)"),
        (0x898, "Estágio (0x898)"),
        (0x8C0, "Timing (0x8C0)"),
        (0x8C4, "Ângulo (0x8C4)"),
    ]
}

private extension RapooOperationTracker.Outcome {
    /// Falha ou desconexão: a gravação pode ter ocorrido só em parte.
    var isUnconfirmed: Bool {
        switch self {
        case .failure, .interrupted: return true
        case .pending, .success: return false
        }
    }
}
