# 2026-10-04 审查修复说明

基准提交：`61fa47952cdc34407b0faf0f96341ea6a830f7b9`。修复版本：1.4.0。

## 审查项处理

| 审查项 | 本次处理 | 主要位置 |
| --- | --- | --- |
| 1. 主额度解析不确定 | 官网与本地事件分开解析；主额度采用明确路径，附加额度独立 ID；未知结构明确报错；附加模型额度不替代菜单栏主标题 | UsageParser.swift、UsageModels.swift |
| 2. 官网异常被本地回退掩盖 | 保留最后成功值、来源和采集时间，更新尝试时间和错误，标记历史读数；历史及本地读数不通知 | UsageModels.swift、UsageMonitor.swift、PopoverView.swift |
| 3. 金额误作剩余 100% | 引入 quota 与 amount 类型，金额保留 Decimal 和币种，展示时本地化；不进入主额度选择和百分比图形；文字及提示显示金额 | UsageModels.swift、CursorAccount.swift、MenuBarLabel.swift、MenuBarAppearance.swift |
| 4. headline 随输入顺序变化 | 先确定最低余量，再筛选最低值加 5 个百分点以内的窗口，按窗口长度、余量及 ID 稳定选择 | UsageModels.swift |
| 5. 关闭查询仍显示旧实时值 | 三个独立开关；暂停服务保留弹窗旧值，菜单栏隐藏或标记槽位不可用；手动刷新遵循开关 | UsageMonitor.swift、SettingsView.swift、MenuBarLabel.swift |
| 6. 外观调整产生网络请求 | 保存偏好、刷新界面、重设计时器和查询分开；通知阈值仅基于现有有效读数重新评估 | UsageMonitor.swift、SettingsView.swift |
| 7. 图形电量槽位不更新 | batteryNeeded 同时覆盖独立电量、纯电量样式以及当前图形中的电量槽位，设置使用相同规则 | UsageMonitor.swift、SettingsView.swift |
| 8. Cursor 备用请求与结果发布 | 识别按量明确停用，记住可用接口，25 秒总预算；取消与 429 立即停止备用请求；各服务独立发布；Retry-After 与指数退避 | CursorAccount.swift、ProviderSupport.swift、UsageMonitor.swift |
| 9. 日志准确性与效率 | 使用事件时间和账户匹配；有效期 24 小时；寻找最近 20 个文件；每分钟缓存目录索引，按追加偏移读取，保存不完整行；账号切换清理读数和通知周期 | SessionLogReader.swift、UsageModels.swift、UsageMonitor.swift |
| 10. 状态与调度拆分 | AccountState 枚举负责业务判断；提取 RefreshPolicy、共享 HTTP 与退避、诊断模块；Provider 加载器可注入以测试 | UsageModels.swift、RefreshPolicy.swift、ProviderSupport.swift、Diagnostics.swift |
| 11. 发布验证与文档 | 免费 ad hoc 签名、Hardened Runtime；通用构建、离线测试、DMG 校验、ZIP、SHA-256、构建信息、GitHub Actions；MIT 许可证、双语说明、截图、变更日志和贡献规范 | scripts、.github、README.md、LICENSE |
| 12. 首次使用与异常恢复 | 首次引导与凭据位置说明；登录帮助；历史、暂停和未知状态；虚线图形区分未知与耗尽；白名单诊断导出；按需检查 GitHub 最新版本并提供下载链接 | SettingsView.swift、PopoverView.swift、Diagnostics.swift、UpdateChecker.swift |
| Cursor 文案覆盖结构化数字 | remaining 与 limit 优先，文案只作兜底；冲突显示提示 | CursorAccount.swift |

另修复了 Cursor 的 `break` 只退出 switch、未结束请求循环的问题，以及现有 AppIcon 图像尺寸不匹配产生的构建警告。

## 验证

- 32 项离线 XCTest 用例通过，包括主与附加额度、未知结构、金额展示、Cursor 字段冲突、所有 headline 排列、状态合并、账户切换、暂停服务、无网络的外观调整、电量依赖、日志时间与分段追加、429、取消、独立发布、旧任务不能覆盖新结果、更新版本比较等。
- Swift 全源文件针对 macOS 14 类型检查通过。
- Xcode Release 通用构建通过，包含 arm64 和 x86_64。
- `codesign --verify --deep --strict` 通过，签名标志为 adhoc 与 runtime。
- DMG 完整性与 DMG、ZIP 的 SHA-256 检查通过。
- 项目 plist、脚本语法及 Git diff 空白检查通过。
- 中文、英文及阿拉伯语截图来自实际 SwiftUI 视图和模拟数据，未查询真实服务账号。

## 明确保留的限制

遵循项目所有者无需付费开发者账号的要求，不配置 Developer ID 签名或 Apple 公证。安装包未公证，首次安装可能需要 Gatekeeper 例外；README 提供核验与安装说明，不将“已损坏”提示一概解释为无害。

没有用真实账户验证接口兼容性、模型耗尽规则或通知投递。维持已知短时主窗口的耗尽暂停规则，更多模型和额外消费的阻断条件留待真实响应验证。

日志缺少明确账户标识时会被忽略，不猜测归属。目录扫描仍是定期遍历，但索引缓存和读取量有限制；大目录的首次扫描可能耗时，最近 20 个文件以外的额度事件可能遗漏。

UsageMonitor 仍负责原生计时器、唤醒监听和通知授权；本次提取可独立验证的规则和模块，未做一次性的全面重构。恢复额度通知和服务显示排序可按实际使用需求继续扩展。

本次截图检查不等于真实多显示器、小屏、VoiceOver、钥匙串提示、开机启动或完整键盘交互验收。发布工作流生成供审核的产物，不自动公开发布版本。
