#!/usr/bin/env swift
//
// Probe ao vivo do canal de configuração do Rapoo VT9 Pro.
//
//   swift script/rapoo_probe.swift            leitura única
//   swift script/rapoo_probe.swift --watch    repete a cada 2 s
//
// Conversa direto com o mouse por IOKit, sem o aplicativo: encontra o device
// que expõe a coleção 0xFF00:0x000E, mede a latência das respostas e
// imprime os registradores no formato do firmware (ver docs/RAPOO_PROTOCOLO.md).
//
// É a ferramenta de referência para separar "o mouse não responde" de
// "o aplicativo não lê".

import Foundation
import IOKit
import IOKit.hid

let vendorID = 0x24AE
let configReportID = 0xBA
let configUsagePage = 0xFF00
let configUsage = 0x000E
let frameLength = 31

/// Endereços do register map (base do perfil 0 = 0x600 + offsets).
let registers: [(address: Int, length: Int, label: String)] = [
    (0x880, 4, "polling"),
    (0x884, 4, "sensor (lift-off / motion sync)"),
    (0x888, 16, "tabela de DPI"),
    (0x898, 4, "estágio ativo"),
    (0x8C0, 4, "timing (debounce / sleep / flags)"),
    (0x8C4, 4, "ângulo do sensor"),
]

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func findDevice() -> (IOHIDDevice, Int)? {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    IOHIDManagerSetDeviceMatching(manager, ["VendorID": vendorID] as CFDictionary)
    IOHIDManagerOpen(manager, 0)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                    "kCFRunLoopDefaultMode" as CFString)
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
        return nil
    }
    for device in devices {
        guard let descriptor = IOHIDDeviceGetProperty(device,
                "ReportDescriptor" as CFString) as? Data else { continue }
        let bytes = Array(descriptor)
        var hasCollection = false
        if bytes.count > 5 {
            for index in 0..<(bytes.count - 5) where bytes[index] == 0x06
                && bytes[index + 1] == 0x00 && bytes[index + 2] == 0xFF
                && bytes[index + 3] == 0x09 && bytes[index + 4] == 0x0E {
                hasCollection = true
                break
            }
        }
        guard hasCollection else { continue }
        let productID = (IOHIDDeviceGetProperty(device, "ProductID" as CFString)
                         as? NSNumber)?.intValue ?? 0
        return (device, productID)
    }
    return nil
}

guard let (device, productID) = findDevice() else {
    print("Nenhum Rapoo com a coleção \(String(configUsagePage, radix: 16)):\(String(configUsage, radix: 16)) encontrado.")
    print("Conecte o mouse pelo cabo ou pareie o receptor e rode de novo.")
    exit(1)
}
guard IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else {
    print("Não foi possível abrir o device (permissão de Monitoramento de Entrada?).")
    exit(1)
}
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(),
                               "kCFRunLoopDefaultMode" as CFString)
print("Device: pid=0x\(String(productID, radix: 16))  (0x418A = cabo, 0x185A = receptor)")

/// Envia um frame de comando (o buffer de saída leva o report ID no byte 0).
func send(command: UInt8, address: Int, data: [UInt8] = []) {
    var payload = [UInt8](repeating: 0, count: frameLength)
    payload[0] = 0xA5                       // byte de conexão
    payload[1] = command                    // comando
    payload[2] = UInt8(data.count)          // tamanho do payload
    payload[3] = UInt8(address & 0xFF)
    payload[4] = UInt8((address >> 8) & 0xFF)
    payload[5] = UInt8((address >> 16) & 0xFF)
    payload[6] = UInt8((address >> 24) & 0xFF)
    for (index, byte) in data.enumerated() where 7 + index < frameLength {
        payload[7 + index] = byte
    }
    var report = [UInt8](repeating: 0, count: frameLength + 1)
    report[0] = UInt8(configReportID)
    for (index, byte) in payload.enumerated() { report[index + 1] = byte }
    _ = report.withUnsafeBufferPointer { pointer in
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(configReportID),
                              pointer.baseAddress!, CFIndex(report.count))
    }
}

/// Lê o slot de resposta do aparelho.
func readAnswer() -> [UInt8]? {
    var report = [UInt8](repeating: 0, count: 32)
    var length: CFIndex = 32
    let result = report.withUnsafeMutableBufferPointer { pointer in
        IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(configReportID),
                             pointer.baseAddress!, &length)
    }
    guard result == kIOReturnSuccess, length > 0, length <= 32 else { return nil }
    var bytes = Array(report[0..<length])
    if bytes.count == 32 && bytes[0] == UInt8(configReportID) { bytes.removeFirst() }
    return bytes
}

/// Lê um registrador: pergunta duas vezes (o slot do aparelho guarda só a
/// última resposta) e usa a segunda.
func readRegister(address: Int, length: Int) -> (bytes: [UInt8], latency: Double)? {
    let start = Date()
    send(command: 0xA4, address: address)
    Thread.sleep(forTimeInterval: 0.035)
    _ = readAnswer()
    send(command: 0xA4, address: address)
    Thread.sleep(forTimeInterval: 0.035)
    guard let answer = readAnswer(), answer.count >= 4 + length else { return nil }
    return (Array(answer[4..<(4 + length)]), Date().timeIntervalSince(start))
}

func batteryReading() -> String {
    send(command: 0xAA, address: 0)
    Thread.sleep(forTimeInterval: 0.035)
    guard let answer = readAnswer(), answer.count >= 3 else { return "sem resposta" }
    let percent = answer[2]
    let charging = answer[1] == 2
    return "\(percent)% \(charging ? "carregando" : "descarregando")"
}

func sweep() {
    print("\n== registradores ==")
    for register in registers {
        if let result = readRegister(address: register.address, length: register.length) {
            print(String(format: "0x%03X %-32@ %@  (%.0f ms)",
                         register.address,
                         register.label as NSString,
                         hex(result.bytes),
                         result.latency * 1000))
        } else {
            // Mostra o que o slot contém: com o mouse parado, ele segue com a
            // última resposta (tipicamente a de bateria, 3 bytes).
            let slot = readAnswer().map { hex($0) } ?? "vazio"
            print(String(format: "0x%03X %-32@ <sem resposta>  slot=[%@] — mexa no mouse",
                         register.address, register.label as NSString, slot))
        }
    }
    print("\n== bateria ==")
    print("0xAA: \(batteryReading())")
}

print("""
O firmware do VT9 Pro só responde o canal 0xBA com o mouse em movimento.
Mova o mouse durante a leitura se as respostas vierem vazias.
""")

sweep()

if CommandLine.arguments.contains("--watch") {
    print("\n--watch: repetindo a cada 2 s (Ctrl-C para sair)")
    while true {
        Thread.sleep(forTimeInterval: 2)
        sweep()
    }
}
