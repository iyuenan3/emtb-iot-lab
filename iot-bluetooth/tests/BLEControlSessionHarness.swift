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
            !notificationFirst.canStartAction,
            "完成后仍不得在同一连接执行第二个动作"
        )

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
        require(!writeFirst.actionAttempted, "新连接必须允许重新选择一次动作")
        require(VehicleLockState.locked.matches(.lock), "关锁态必须匹配关锁动作")
        require(!VehicleLockState.locked.matches(.unlock), "关锁态不得匹配开锁动作")
    }
}
