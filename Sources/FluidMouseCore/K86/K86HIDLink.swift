import Foundation

/// Camada de I/O HID como **porta injetável**: o serviço de transporte depende
/// desta abstração, não de IOKit — em testes entra um fake com comportamento
/// roteirizado, em produção entra `IOKitHIDLink` (`Services/K86HidService.swift`).
///
/// Erros usam códigos `IOReturn` (`Int32`) para não esconder falha como valor
/// zero: nenhum caminho devolve "0" no lugar de erro.
package enum K86ReportError: Error, Equatable {
    case reportFailed(code: Int32)
    case shortBuffer(expected: Int, got: Int)
}

package struct K86LinkProperties: Equatable, Sendable {
    package let vendorID: Int
    package let productID: Int
    package let locationID: Int
    package let maxFeatureReportSize: Int?
    package let reportDescriptor: [UInt8]?
    /// Identidade ÚNICA do device no IORegistry (IORegistryEntryID): teclado/
    /// consumer/config de um MESMO composto compartilham LocationID — a remoção
    /// só é atribuída ao vínculo com o entryID EXATO (rev. 3 do líder).
    package let registryEntryID: Int?

    package init(vendorID: Int, productID: Int, locationID: Int,
                 maxFeatureReportSize: Int?, reportDescriptor: [UInt8]?,
                 registryEntryID: Int? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.maxFeatureReportSize = maxFeatureReportSize
        self.reportDescriptor = reportDescriptor
        self.registryEntryID = registryEntryID
    }
}

package protocol K86HIDLink: AnyObject {
    /// Propriedades read-only (IORegistry/descritor) — nenhum report usado.
    var properties: K86LinkProperties { get }

    /// Abertura **não-exclusiva** (`kIOHIDOptionsTypeNone`, IOHIDKeys.h §231;
    /// NUNCA `kIOHIDOptionsTypeSeizeDevice`, IOHIDDevice.h §93).
    func open() -> Bool
    func close()

    /// `IOHIDDeviceSetReport(feature, reportID, payload)` — payload é o frame
    /// inteiro (64 B do K86), SEM prefixo de report ID: o descritor real
    /// (hex do líder) não tem item `85` ⇒ unnumbered ⇒ o ID vai no parâmetro
    /// (IOHIDDevice.h, doc de `IOHIDDeviceSetReport`: o primeiro byte só
    /// carrega o ID quando o device suporta múltiplos reports).
    func setFeature(reportID: Int, payload: [UInt8]) throws

    /// `IOHIDDeviceGetReport(feature, reportID, buffer)` — buffer pré-alocado
    /// de `byteCount`; devolve os bytes efetivamente lidos (comprimento real
    /// via `pReportLength`, IOHIDDevice.h doc de `IOHIDDeviceGetReport`).
    /// Resposta curta é devolvida como veio — quem enche de zero é proibido.
    func getFeature(reportID: Int, byteCount: Int) throws -> [UInt8]
}
