import Foundation
import FluidMouseCore

/// Rascunho da tabela de DPI, em unidades de DPI (não de registro). O mouse
/// grava X e Y juntos com a mesma tabela, então há um único valor por estágio.
/// Lógica pura: sem HID, testada em `RapooDpiDraftTests`.
struct RapooDpiDraft: Equatable {
    var stages: [Int]
    var enabledStages: Int

    static let stageCount = 7
    static let dpiRange = 100...26_000
    static let enabledRange = 2...7

    /// Tabela lida do mouse, convertida para DPI com a escala atual.
    static func confirmed(_ table: RapooProtocol.DpiTable?, scale: Int) -> RapooDpiDraft? {
        guard let table else { return nil }
        let factor = max(scale, 1)
        return RapooDpiDraft(stages: table.stages.map { $0 * factor }, enabledStages: table.enabledStages)
    }

    /// O que a tela mostra: o rascunho quando existe, senão a leitura confirmada.
    static func displayed(draft: RapooDpiDraft?, confirmed: RapooDpiDraft?) -> RapooDpiDraft? {
        draft ?? confirmed
    }

    /// Há edição que ainda não foi confirmada pelo mouse.
    static func isDirty(draft: RapooDpiDraft?, confirmed: RapooDpiDraft?) -> Bool {
        guard let draft else { return false }
        return draft != confirmed
    }

    /// Após sucesso da gravação enviada, o rascunho some só se ainda for o
    /// mesmo que foi enviado; uma edição nova nunca é apagada por um sucesso antigo.
    static func afterSuccess(current: RapooDpiDraft?, submitted: RapooDpiDraft) -> RapooDpiDraft? {
        current == submitted ? nil : current
    }

    mutating func setStage(_ slot: Int, to value: Int) {
        guard stages.indices.contains(slot) else { return }
        stages[slot] = value
    }

    /// Motivo para não gravar, ou nil. A tabela precisa ter exatamente 7
    /// estágios. Valores fora da faixa ou fora do passo da escala são
    /// sinalizados, nunca corrigidos em silêncio.
    func problem(scale: Int) -> String? {
        let factor = max(scale, 1)
        guard stages.count == Self.stageCount else { return "A tabela de DPI precisa ter exatamente 7 estágios." }
        guard Self.enabledRange.contains(enabledStages) else { return "Escolha de 2 a 7 estágios." }
        for (index, dpi) in stages.enumerated() where !Self.dpiRange.contains(dpi) || dpi % factor != 0 {
            return "Estágio \(index + 1): use de 100 a 26.000 DPI, múltiplo de \(factor)."
        }
        return nil
    }
}
