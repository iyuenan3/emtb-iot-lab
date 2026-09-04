import Foundation

enum HarnessError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw HarnessError.failed(message) }
}

private func requireDirective(
    _ actual: BikeDirective?,
    _ expected: BikeDirective,
    _ message: String
) throws {
    try require(actual == expected, "\(message): \(String(describing: actual))")
}

private func response(command: UInt8, payload: [UInt8]) -> BikeFrame {
    BikeFrame(connectionKey: 0x59, command: command, payload: payload)
}

private func testDocumentedAuthenticationVector() throws {
    let actual = try BikeWireProtocol.authenticationFrame(
        deviceKey: "OmniW4GX",
        random: 0x1E
    )
    let expected = Data([
        0xA3, 0xA4, 0x08, 0x50, 0x1E, 0x1F,
        0x51, 0x73, 0x70, 0x77, 0x49, 0x2A, 0x59, 0x46, 0x01
    ])
    try require(actual == expected, "协议文档认证向量不匹配")
}

private func testRoundTripAndPayloads() throws {
    let frame = BikeWireProtocol.makeFrame(
        command: 0x31,
        payload: [0x01, 0x22, 0x33],
        connectionKey: 0x59,
        random: 0x7E
    )
    let decoded = try BikeWireProtocol.decode(frame)
    try require(decoded == BikeFrame(
        connectionKey: 0x59,
        command: 0x31,
        payload: [0x01, 0x22, 0x33]
    ), "协议帧往返失败")

    let unlock = try BikeRequest.control(.unlock).payload(
        deviceKey: "12345678",
        timestamp: 0x01020304
    )
    try require(
        unlock == [0x01, 0, 0, 0, 1, 1, 2, 3, 4, 0],
        "开锁载荷的用户 ID 或时间戳字节序错误"
    )
    let lock = try BikeRequest.control(.lock).payload(
        deviceKey: "12345678",
        timestamp: 0
    )
    try require(lock == [0x01], "关锁载荷错误")
    let receipt = try BikeRequest.receipt(.unlock).payload(
        deviceKey: "12345678",
        timestamp: 0
    )
    try require(receipt == [0x02], "控制回执载荷错误")
}

private func testEngineOrder(action: BikeAction) throws {
    var engine = BikeControlEngine(action: action)
    try requireDirective(
        try engine.notificationReady(),
        .wait(.beforeAuthentication),
        "通知就绪后必须先等待"
    )
    try require(BikeWait.beforeAuthentication.seconds == 0.6, "认证前等待被修改")
    try requireDirective(
        try engine.timerElapsed(.beforeAuthentication),
        .send(.authentication),
        "认证步骤错误"
    )

    let authResponseFirst = try engine.receive(response(command: 0x01, payload: [1, 0x59]))
    try require(authResponseFirst == nil, "未收到写回调时不应推进认证")
    try requireDirective(
        try engine.writeSucceeded(),
        .send(.lockInformation),
        "认证后必须读取锁信息"
    )

    let lockInfoWriteFirst = try engine.writeSucceeded()
    try require(lockInfoWriteFirst == nil, "锁信息响应前不应推进")
    try requireDirective(
        try engine.receive(response(command: 0x31, payload: Array(repeating: 0, count: 7))),
        .send(.vehicleInformation),
        "锁信息后必须读取车辆信息"
    )

    let vehicleResponseFirst = try engine.receive(
        response(command: 0x60, payload: Array(repeating: 0, count: 8))
    )
    try require(vehicleResponseFirst == nil, "车辆信息写回调前不应推进")
    try requireDirective(
        try engine.writeSucceeded(),
        .wait(.beforeControl),
        "初始化后必须静默等待"
    )
    try require(BikeWait.beforeControl.seconds == 1.0, "控制前静默时间被修改")
    try require(!engine.controlWasSent, "等待阶段不应标记已发送控制")
    try requireDirective(
        try engine.timerElapsed(.beforeControl),
        .send(.control(action)),
        "静默后控制步骤错误"
    )
    try require(engine.controlWasSent, "发送控制时必须标记结果可能未知")

    let controlWriteFirst = try engine.writeSucceeded()
    try require(controlWriteFirst == nil, "控制响应前不应推进")
    let controlPayload = action == .unlock
        ? [UInt8(1), 0, 0, 0, 0]
        : [UInt8(1), 0, 0, 0, 0, 0, 0, 0, 0]
    try requireDirective(
        try engine.receive(response(command: action.command, payload: controlPayload)),
        .send(.receipt(action)),
        "控制成功后必须写回执"
    )
    try requireDirective(
        try engine.writeSucceeded(),
        .wait(.beforeDisconnect),
        "回执后必须静默等待"
    )
    try require(BikeWait.beforeDisconnect.seconds == 0.8, "断开前静默时间被修改")
    try requireDirective(
        try engine.timerElapsed(.beforeDisconnect),
        .finish(accepted: true),
        "断开前流程结束错误"
    )
}

private func testMalformedControlResponseStops() throws {
    var engine = BikeControlEngine(action: .unlock)
    _ = try engine.notificationReady()
    _ = try engine.timerElapsed(.beforeAuthentication)
    _ = try engine.writeSucceeded()
    _ = try engine.receive(response(command: 0x01, payload: [1, 0x59]))
    _ = try engine.writeSucceeded()
    _ = try engine.receive(response(command: 0x31, payload: Array(repeating: 0, count: 7)))
    _ = try engine.receive(response(command: 0x60, payload: Array(repeating: 0, count: 8)))
    _ = try engine.writeSucceeded()
    _ = try engine.timerElapsed(.beforeControl)
    _ = try engine.writeSucceeded()
    do {
        _ = try engine.receive(response(command: 0x05, payload: [1]))
        throw HarnessError.failed("不完整控制响应被错误接受")
    } catch BikeEngineError.malformedResponse {
        return
    }
}

@main
enum BikeProtocolHarness {
    static func main() throws {
        try testDocumentedAuthenticationVector()
        try testRoundTripAndPayloads()
        try testEngineOrder(action: .unlock)
        try testEngineOrder(action: .lock)
        try testMalformedControlResponseStops()
        print("BikeProtocolHarness: PASS")
    }
}
