import Foundation

@main
struct BLEControlSessionHarness {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }

    static func main() {
        var notificationFirst = BLEControlSession()
        notificationFirst.acceptAuthentication()
        require(
            notificationFirst.canStartAction,
            "认证通知先于写入完成回调时，控制必须立即可用"
        )
        notificationFirst.noteWriteCompleted()
        require(
            notificationFirst.canStartAction,
            "迟到的写入完成回调不得关闭控制入口"
        )
        require(notificationFirst.begin(.unlock), "首次开锁必须可以开始")
        require(!notificationFirst.canStartAction, "同一连接不得开始第二个动作")
        require(
            notificationFirst.recordResult(
                command: OmniCommand.unlock.rawValue,
                value: 1
            ) == true,
            "开锁成功结果必须归属当前动作"
        )
        require(
            notificationFirst.recordResult(
                command: OmniCommand.unlock.rawValue,
                value: 1
            ) == nil,
            "重复结果必须被忽略"
        )
        notificationFirst.finishAction()
        require(
            notificationFirst.canStartAction,
            "完成回包和状态回读后必须允许在同一连接执行下一动作"
        )
        require(notificationFirst.begin(.lock), "同一认证连接必须允许继续关锁")
        require(
            notificationFirst.recordResult(command: OmniCommand.lock.rawValue, value: 1) == true,
            "第二个动作必须独立记录结果"
        )
        notificationFirst.finishAction()

        var writeFirst = BLEControlSession()
        writeFirst.noteWriteCompleted()
        require(!writeFirst.canStartAction, "只有写入回调不能冒充认证成功")
        writeFirst.acceptAuthentication()
        require(
            writeFirst.canStartAction,
            "写入完成回调先于认证通知时，认证后控制必须可用"
        )
        require(writeFirst.begin(.lock), "首次关锁必须可以开始")
        require(
            writeFirst.recordResult(command: OmniCommand.unlock.rawValue, value: 1) == nil,
            "反向命令结果不得结束当前关锁"
        )
        require(
            writeFirst.recordResult(command: OmniCommand.lock.rawValue, value: 2) == false,
            "关锁拒绝结果必须保留"
        )

        writeFirst.reset()
        require(!writeFirst.isAuthenticated, "断线后必须清除认证状态")
        require(writeFirst.pendingAction == nil, "断线后必须清除待处理动作")
        require(VehicleLockState.locked.matches(.lock), "关锁态必须匹配关锁动作")
        require(!VehicleLockState.locked.matches(.unlock), "关锁态不得匹配开锁动作")

        require(
            OmniProtocol.uint16([0x12, 0x34][...]) == 0x1234,
            "16 位大端解析必须与协议一致"
        )
        require(
            OmniProtocol.uint32([0x01, 0x23, 0x45, 0x67][...]) == 0x01234567,
            "32 位大端解析必须与协议一致"
        )

        let lockDetails = OmniProtocol.lockDetails(
            from: [0xC3, 0x50, 0x41, 0x00, 0x01, 0x02, 0x03]
        )
        require(lockDetails?.0 == .unlocked, "0x31 开锁标志必须正确解析")
        require(lockDetails?.1.voltageMillivolts == 50_000, "0x31 电压必须按毫伏解析")
        require(lockDetails?.1.firmwareVersion == "1.2.3", "0x31 固件版本解析错误")
        require(lockDetails?.1.hasOldRideData == true, "0x31 旧数据标志解析错误")

        let scooter = OmniProtocol.scooterInfo(
            from: [88, 2, 0x00, 0x7B, 0x00, 0x64, 0x01, 0x2C]
        )
        require(scooter?.batteryPercent == 88, "0x60 电量解析错误")
        require(scooter?.rideMode == .medium, "0x60 骑行模式解析错误")
        require(scooter?.speedKPH == 12.3, "0x60 速度缩放错误")
        require(scooter?.tripDistanceMeters == 1_000, "0x60 本次里程缩放错误")
        require(scooter?.remainingDistanceMeters == 3_000, "0x60 剩余里程缩放错误")

        let oldRide = OmniProtocol.oldRideData(
            from: [0, 0, 0, 10, 0, 0, 0, 20, 0, 0, 0, 30]
        )
        require(oldRide?.unlockTimestamp == 10, "0x51 开锁时间解析错误")
        require(oldRide?.durationSeconds == 20, "0x51 时长解析错误")
        require(oldRide?.userID == 30, "0x51 用户 ID 解析错误")
        require(OmniProtocol.externalState(from: 0x10) == .locked, "0x81 上锁状态解析错误")
        require(OmniProtocol.externalState(from: 0x11) == .unlocked, "0x81 解锁状态解析错误")

        let basic = ScooterBasicSettings(
            light: .enabled,
            rideMode: .medium,
            accelerator: .disabled,
            tailLight: .unchanged
        )
        require(basic.payload == [2, 2, 1, 0], "基础设置载荷必须保持文档字段顺序")
        require(!basic.isNoOp, "包含修改项的基础设置不得视为空操作")

        let advanced = ScooterAdvancedSettings(
            persist: true,
            cruise: .enabled,
            startMode: .nonZero,
            lowSpeedLimit: 10,
            mediumSpeedLimit: 18,
            highSpeedLimit: 25
        )
        require(
            advanced.payload == [1, 2, 1, 10, 18, 25],
            "高级设置载荷必须保持文档字段顺序"
        )
        do {
            try advanced.validate()
        } catch {
            fatalError("文档范围内的高级设置必须通过校验")
        }

        require(ExternalDeviceOperation.unlock(.battery).code == 0x01, "电池锁解锁码错误")
        require(ExternalDeviceOperation.lock(.wheel).code == 0x12, "车轮锁上锁码错误")
        require(ExternalDeviceOperation.query(.cable).code == 0x23, "钢缆锁查询码错误")
    }
}
