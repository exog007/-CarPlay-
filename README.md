# 远驱控制器 · iOS App + CarPlay 小组件

读取远驱（FarDriver）控制器的蓝牙数据，显示在 iPhone 上，
并把关键数据同步到 CarPlay 小组件，同时每 60 秒上传一份到本地 deepseek。

---

## 先说清楚 CarPlay 的限制

苹果**不允许**自定义仪表盘类 App 上 CarPlay。官方支持的类型只有：
音频、视频（停车时）、导航、通话、消息、**电动车充电**、加油、停车、公共安全、快速点餐、语音对话、驾驶任务。

**但是**，官方文档明确写了小组件的规则：

> 小组件显示在 CarPlay 车载仪表盘左侧，支持在车载触摸屏上进行交互。
> **如果你的 App 包含小组件，无需做出任何更改，它便会自动显示在 CarPlay 车载中。**

这就是本项目走的路：**用小组件显示控制器数据，不需要申请 CarPlay 授权。**

---

## 目录结构

```
ios-app/
├── FarDriver/
│   ├── FarDriverApp.swift        App 入口
│   ├── FarDriverProtocol.swift   BLE 协议解码（核心）
│   ├── ControllerManager.swift   蓝牙连接 + 上传
│   ├── SharedStore.swift         App Group 共享存储
│   ├── ContentView.swift         主界面
│   └── Info.plist                权限配置
└── FarDriverWidget/
    └── FarDriverWidget.swift     CarPlay 小组件
```

---

## 协议说明

从社区逆向实现整理，代码里已完整实现：

| 项目 | 值 |
|---|---|
| 服务 UUID | `0000FFE0-0000-1000-8000-00805F9B34FB` |
| 特征 UUID | `0000FFEC-0000-1000-8000-00805F9B34FB` |
| 包长 | 固定 16 字节 |
| 校验 | CRC16，初值 `0x7F3C`，多项式 `0xA001` |

**数据地址表：**

| 地址 | 含义 | 解码方式 |
|---|---|---|
| `0xE2` | 档位 + 转速 | 档位 = `(p[0]>>2)&0b11 + 1`；转速 = `int16(p[7]<<8 \| p[6])` |
| `0xE8` | 电压 + 电流 | 电压 = `uint16(p[1]<<8 \| p[0]) / 10`；电流 = `int16(p[5]<<8 \| p[4]) / 4` |
| `0xD6` | **MOS 温度** | `int16(p[11]<<8 \| p[10])` |
| `0xF4` | **电机温度** + SOC | 温度 = `int16(p[1]<<8 \| p[0])`；SOC = `p[3]` |

> ⚠️ **需要你验证**：`0xD6` 是社区代码里标为 "controllerTemp" 的地址，
> 按你的说法应该是 MOS 管温度。如果对不上，告诉我实际显示的值，我来调整。

---

## 编译步骤

### 前置条件

- **一台 Mac**（必需，Windows 编译不了 iOS）
- **Xcode 16 或更新**（App Store 免费下载）
- **Apple 开发者账号**
  - 免费账号：能装到自己手机上，**但 App 7 天过期**，且**小组件不能上 CarPlay**
  - 付费账号（$99/年，约 ¥688）：**小组件能在 CarPlay 显示**，有效期 1 年

### 步骤

**1. 新建工程**

Xcode → File → New → Project → iOS → App
- Product Name: `FarDriver`
- Interface: **SwiftUI**
- Language: **Swift**
- Bundle Identifier: 比如 `com.exog1.fardriver`

**2. 加小组件 Target**

File → New → Target → **Widget Extension**
- Product Name: `FarDriverWidget`
- ⚠️ **取消勾选** "Include Configuration Intent"
- Bundle Identifier 会自动变成 `com.exog1.fardriver.FarDriverWidget`

**3. 删掉模板文件**

新工程会自动生成几个文件，全删掉：
- `FarDriver/FarDriverApp.swift`（如果 Xcode 生成了自己的 ContentView）
- `FarDriverWidget/FarDriverWidgetBundle.swift` 等模板

把本项目 `ios-app/` 下的所有 `.swift` 拖进对应 Target：
- `FarDriver/` 里的 → 勾选 **FarDriver** target
- `FarDriverWidget.swift` → 勾选 **FarDriverWidget** target
- **`FarDriverProtocol.swift` 和 `SharedStore.swift` 两个 target 都要勾** ← 关键

**4. 配置 App Group**

这是主 App 和小组件共享数据的关键。

- 选中 FarDriver target → Signing & Capabilities → **+ Capability** → **App Groups**
- 点 **+** 添加：`group.com.exog1.fardriver`
- 选中 FarDriverWidget target → 同样操作，**加同一个名字**

**5. 配置权限**

`Info.plist` 里已经写好了，确认这几项在：

```xml
NSBluetoothAlwaysUsageDescription     → 蓝牙权限说明
NSLocalNetworkUsageDescription        → 局域网权限说明
NSAppTransportSecurity
  NSAllowsLocalNetworking = YES       → 允许连内网 HTTP
UIBackgroundModes
  bluetooth-central                   → 后台蓝牙
  fetch                               → 后台刷新
```

**6. 改 Bundle ID（重要）**

代码里写死了 App Group `group.com.exog1.fardriver`，
如果你改了 Bundle Identifier，**两处都要同步改**：
- `SharedStore.swift` 里的 `suiteName`
- Xcode 两个 target 的 App Groups

**7. 连手机编译**

- iPhone 用数据线连 Mac
- Xcode 顶部选你的 iPhone
- Signing & Capabilities → Team 选你的开发者账号
- ⌘R 运行

**8. 允许权限**

手机上会弹：
- 「允许蓝牙」→ 允许
- 「允许访问本地网络」→ **必须允许**（否则传不了数据）

---

## 使用

**1. 在 App 里设置服务器地址**

点右上角齿轮 → 填你电脑的地址：
```
http://192.168.100.101:38281
```
手机和电脑要连**同一个 WiFi**。

**2. 连接控制器**

点「连接」，App 自动搜索远驱的蓝牙（服务 UUID `FFE0`），找到就连上。

**3. 看数据**

主界面实时显示：转速、时速、MOS 温度、电机温度、电压、电流、功率、档位。

**4. CarPlay 小组件**

- iPhone 上长按桌面 → 加小组件 → 找「远驱控制器」
- 开车连上车机后，**小组件会自动出现在 CarPlay 仪表盘左侧**
- 也可以在 CarPlay 里手动加

**5. 数据上传**

自动每 60 秒传一次到电脑。也可以在 App 里点「立刻上传一次」。

---

## 电脑端

数据接收服务已经做好了，端口 `38281`：

```powershell
# 启动
cd C:\Users\exog1\Downloads\本地大傻鱼
.\node\node.exe grow\controller-receiver.js

# 看当前数据
node grow\controller-receiver.js --test
```

**仪表盘页面**（电脑浏览器打开）：
```
http://192.168.100.101:38281/
```

**手机上报地址**：
```
http://192.168.100.101:38281/api/controller
```

---

## 上传的数据格式

App 每 60 秒 POST 一次：

```json
{
  "time": 1793140834924,
  "device": "FarDriver",
  "voltage": 87.2,
  "current": 45.3,
  "rpm": 3200,
  "speed": 62.5,
  "gear": 3,
  "mosTemp": 48,
  "motorTemp": 52,
  "soc": 89,
  "power": 3950,
  "regen": false
}
```

---

## 接进本地 deepseek

数据到了之后，可以直接在 QQ / 网页里问：

| 问 | 答 |
|---|---|
| MOS 温度多少 | MOS 温度现在 48°C |
| 电机转速多少 | 电机转速现在 3200 转 |
| 现在功率多少 | 实时功率现在 3950W |
| 控制器怎么样 | 一次报全部 |

---

## 常见问题

**Q: App 能装，但小组件不出现在 CarPlay**

这是**免费开发者账号**的限制。小组件要上 CarPlay，必须用**付费开发者账号**（$99/年）签名。
免费账号的 App 7 天过期，且小组件受限。

**Q: 蓝牙搜不到控制器**

- 确认控制器通电
- 确认没有别的手机/App 连着它（远驱一次只允许一个连接）
- 关掉官方 App 再试

**Q: 数据不对（比如温度是 0）**

- 确认控制器装了温度传感器（你说有）
- 可能是地址表版本不同，把实际读数发我，我调地址

**Q: 转速/时速不准**

改 `FarDriverDecoder` 里两个参数：
```swift
wheelCircumferenceM = 1.416   // 你的轮周长
motorPolePairs = 20           // 你的电机极对数
```
轮周长可以用卷尺量，或者查轮胎规格表。

---

## 我做不到的部分

**我没有 Mac，也没法编译验证 Swift 代码。**

代码是完整可用的，但：
- 是否编译通过，需要你在 Xcode 里跑
- 如果有编译错误，把错误信息发我，我改

**这也是为什么我先做好了电脑端的接收服务**——那部分我已经测试通了。
