//
//  ControllerParams.swift
//  控制器参数表（官方原文）
//
//  数据来源：远驱电控 App 2.2.7（正版）MotorNet6.dll 资源区
//  这些是控制器主动上报的寄存器内容，本 App 只读不写
//

import Foundation

/// 一个可显示的参数项
struct ParamItem: Identifiable, Hashable {
    let id = UUID()
    let key: String        // 内部键名（对应 DLL 里的标识）
    let title: String      // 中文名（官方原文）
    let unit: String       // 单位，没有就空
    let format: String     // 显示格式，例如 "%.1f"
    let enumMap: [Int: String]?   // 枚举值映射
}

/// 参数分组
struct ParamGroup: Identifiable {
    let id = UUID()
    let title: String
    let items: [ParamItem]
}

enum ControllerParams {

    // MARK: - 电机

    static let motor = ParamGroup(title: "电机", items: [
        ParamItem(key: "PolePairs",   title: "极对数",     unit: "",    format: "%d",  enumMap: nil),
        ParamItem(key: "MotorDir",    title: "电机方向",   unit: "",    format: "%d",
                  enumMap: [0: "正转", 1: "反转"]),
        ParamItem(key: "RatedSpeed",  title: "额定转速",   unit: "rpm", format: "%d",  enumMap: nil),
        ParamItem(key: "RatedVol",    title: "额定电压",   unit: "V",   format: "%d",  enumMap: nil),
        ParamItem(key: "RatedPower",  title: "额定功率",   unit: "W",   format: "%d",  enumMap: nil),
        ParamItem(key: "MaxSpeed",    title: "最高转速",   unit: "rpm", format: "%d",  enumMap: nil),
        ParamItem(key: "BackSpeed",   title: "后退转速",   unit: "rpm", format: "%d",  enumMap: nil),
    ])

    // MARK: - 电流

    static let current = ParamGroup(title: "电流", items: [
        ParamItem(key: "MaxLineCurr",     title: "最大线电流",     unit: "A", format: "%.1f", enumMap: nil),
        ParamItem(key: "MaxPhaseCurr",    title: "最大相电流",     unit: "A", format: "%.1f", enumMap: nil),
        ParamItem(key: "CustMaxLineCurr", title: "客户最大线电流", unit: "A", format: "%.1f", enumMap: nil),
        ParamItem(key: "CustMaxPhaseCurr",title: "客户最大相电流", unit: "A", format: "%.1f", enumMap: nil),
        ParamItem(key: "IntRes",          title: "连接内阻",       unit: "",  format: "%d",  enumMap: nil),
    ])

    // MARK: - 油门

    static let throttle = ParamGroup(title: "油门", items: [
        ParamItem(key: "ThrottleResp",  title: "油门响应",   unit: "",      format: "%d",
                  enumMap: [0: "线性", 1: "运动", 2: "经济"]),
        ParamItem(key: "AccSens",       title: "加速灵敏度", unit: "",      format: "%d",  enumMap: nil),
        ParamItem(key: "DecSens",       title: "减速灵敏度", unit: "",      format: "%d",  enumMap: nil),
        ParamItem(key: "EcoAcc",        title: "经济加速",   unit: "",      format: "%d",  enumMap: nil),
        ParamItem(key: "ThrottleLow",   title: "油门低阈值", unit: "",      format: "%d",  enumMap: nil),
        ParamItem(key: "ThrottleHigh",  title: "油门高阈值", unit: "",      format: "%d",  enumMap: nil),
        ParamItem(key: "RespMode",      title: "响应模式",   unit: "",      format: "%d",
                  enumMap: [0: "正常响应", 1: "赛道响应"]),
    ])

    // MARK: - 弱磁

    static let fieldWeakening = ParamGroup(title: "弱磁", items: [
        ParamItem(key: "WeakChar",    title: "弱磁特性",     unit: "", format: "%d",
                  enumMap: [0: "快", 1: "中", 2: "慢"]),
        ParamItem(key: "WeakResp",    title: "弱磁响应",     unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "FwReRatio",   title: "弱磁电流系数", unit: "", format: "%d", enumMap: nil),
    ])

    // MARK: - 三档

    static let gears = ParamGroup(title: "三档", items: [
        ParamItem(key: "LowLineCurr",  title: "低速线电流", unit: "%",   format: "%d", enumMap: nil),
        ParamItem(key: "MidLineCurr",  title: "中速线电流", unit: "%",   format: "%d", enumMap: nil),
        ParamItem(key: "LowPhaseCurr", title: "低速相电流", unit: "%",   format: "%d", enumMap: nil),
        ParamItem(key: "MidPhaseCurr", title: "中速相电流", unit: "%",   format: "%d", enumMap: nil),
        ParamItem(key: "LowSpeed",     title: "低速速度",   unit: "rpm", format: "%d", enumMap: nil),
        ParamItem(key: "MidSpeed",     title: "中速速度",   unit: "rpm", format: "%d", enumMap: nil),
    ])

    // MARK: - 能量回馈

    static let regen = ParamGroup(title: "能量回馈", items: [
        ParamItem(key: "StopReCurr",  title: "停止回流",     unit: "A", format: "%.1f", enumMap: nil),
        ParamItem(key: "MaxReCurr",   title: "最大回流",     unit: "A", format: "%.1f", enumMap: nil),
        ParamItem(key: "BackThrPoint",title: "回油门刹车点", unit: "",  format: "%d",  enumMap: nil),
        ParamItem(key: "ReCurrRatio", title: "后退电流比",   unit: "",  format: "%d",  enumMap: nil),
    ])

    // MARK: - 保护

    static let protect = ParamGroup(title: "保护", items: [
        ParamItem(key: "OverVolProtect",   title: "过压保护",       unit: "V", format: "%.1f", enumMap: nil),
        ParamItem(key: "OverVolRestore",   title: "过压恢复",       unit: "V", format: "%.1f", enumMap: nil),
        ParamItem(key: "LowVolProtect",    title: "欠压保护",       unit: "V", format: "%.1f", enumMap: nil),
        ParamItem(key: "LowVolRestore",    title: "欠压恢复",       unit: "V", format: "%.1f", enumMap: nil),
        ParamItem(key: "MotorTempProtect", title: "电机温度保护",   unit: "°C", format: "%d", enumMap: nil),
        ParamItem(key: "MotorTempRestore", title: "电机温度恢复",   unit: "°C", format: "%d", enumMap: nil),
        ParamItem(key: "CtrlTempProtect",  title: "控制器温度保护", unit: "°C", format: "%d", enumMap: nil),
        ParamItem(key: "CtrlTempRestore",  title: "控制器温度恢复", unit: "°C", format: "%d", enumMap: nil),
        ParamItem(key: "ShutDownVol",      title: "自动关机电压",   unit: "V", format: "%.1f", enumMap: nil),
        ParamItem(key: "AlarmDelay",       title: "告警延时",       unit: "ms", format: "%d", enumMap: nil),
    ])

    // MARK: - 功能脚

    static let funcPins = ParamGroup(title: "功能脚", items: [
        ParamItem(key: "BoostPin",   title: "Boost",   unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "CruisePin",  title: "巡航",    unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "StandPin",   title: "边撑",    unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "PPin",       title: "P 档",    unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "FwdPin",     title: "前进",    unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "BackPin",    title: "后退",    unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "HighPin",    title: "高速",    unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "LowPin",     title: "低速",    unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "ChargePin",  title: "充电",    unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "TheftPin",   title: "防盗",    unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "SeatPin",    title: "坐桶",    unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "LimitPin",   title: "限速",    unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "VolSelPin",  title: "电压切换",unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "RepairPin",  title: "一键修复",unit: "", format: "%d", enumMap: nil),
    ])

    // MARK: - 刹车 / 驻车

    static let brake = ParamGroup(title: "刹车", items: [
        ParamItem(key: "BrakeMode",  title: "刹车模式",   unit: "", format: "%d",
                  enumMap: [0: "刹车有效", 1: "反向刹车", 2: "P+刹车", 3: "P+反向刹车", 4: "无效"]),
        ParamItem(key: "FollowMode", title: "跟随",       unit: "", format: "%d",
                  enumMap: [0: "跟随有效", 1: "无效", 2: "电子刹车", 3: "回油门刹车"]),
        ParamItem(key: "ParkMode",   title: "驻坡",       unit: "", format: "%d",
                  enumMap: [0: "防后溜", 1: "开关驻坡", 2: "无效"]),
        ParamItem(key: "PC13Mode",   title: "PC13",       unit: "", format: "%d",
                  enumMap: [0: "浮空行车", 1: "浮空断电", 2: "浮空巡航", 3: "接地巡航"]),
        ParamItem(key: "SeatDelay",  title: "坐桶延时",   unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "ParkTime",   title: "驻车时间",   unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "BlockTime",  title: "堵转时间",   unit: "", format: "%d", enumMap: nil),
    ])

    // MARK: - 仪表 / 轮胎

    static let meter = ParamGroup(title: "仪表与轮胎", items: [
        ParamItem(key: "SpeedPulse",   title: "速度脉冲",     unit: "",   format: "%d", enumMap: nil),
        ParamItem(key: "SpdPulseNum",  title: "速度脉冲基数", unit: "",   format: "%d", enumMap: nil),
        ParamItem(key: "SpeedMeter",   title: "速度表方式",   unit: "",   format: "%d", enumMap: nil),
        ParamItem(key: "WheelWidth",   title: "轮胎宽度",     unit: "",   format: "%d", enumMap: nil),
        ParamItem(key: "WheelRatio",   title: "轮胎扁平率",   unit: "",   format: "%d", enumMap: nil),
        ParamItem(key: "WheelRadius",  title: "轮胎 R",       unit: "",   format: "%d", enumMap: nil),
        ParamItem(key: "RateRatio",    title: "传动速比",     unit: "",   format: "%d", enumMap: nil),
        ParamItem(key: "CanSel",       title: "CAN 通信",     unit: "",   format: "%d",
                  enumMap: [0: "无", 1: "CAN"]),
        ParamItem(key: "TorqueCoeff",  title: "扭矩系数",     unit: "",   format: "%d", enumMap: nil),
    ])

    // MARK: - 温度传感器

    static let sensor = ParamGroup(title: "传感器", items: [
        ParamItem(key: "MotorSensor", title: "位置传感器", unit: "", format: "%d", enumMap: nil),
        ParamItem(key: "TempSensor",  title: "温度传感器", unit: "", format: "%d",
                  enumMap: [0: "无", 1: "PTC", 2: "NTC230K", 3: "KTY84-130",
                            4: "Cacu", 5: "KTY83-122", 6: "NTC10K", 7: "NTC100K"]),
    ])

    /// 精简模式显示的分组（原版精简模式的设计）
    static let simpleGroups: [ParamGroup] = [
        motor, current, throttle, gears, regen, protect, brake
    ]

    /// 专业模式显示的分组（完整）
    static let expertGroups: [ParamGroup] = [
        motor, current, throttle, fieldWeakening, gears, regen,
        protect, funcPins, brake, meter, sensor
    ]
}
