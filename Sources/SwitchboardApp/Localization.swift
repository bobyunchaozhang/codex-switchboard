import Foundation
import SwiftUI

/// App-owned copy is translated at presentation time so cached state can change language immediately.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let preferenceKey = "interfaceLanguage"
    var id: String { rawValue }
    var nativeName: String { self == .english ? "English" : "简体中文" }
    var locale: Locale { Locale(identifier: self == .english ? "en_US" : "zh_CN") }

    func text(_ source: String) -> String {
        self == .english ? source : Self.chinese[source] ?? source
    }

    func format(_ source: String, _ arguments: CVarArg...) -> String {
        String(format: text(source), locale: locale, arguments: arguments)
    }

    func date(_ value: Date, complete: Bool = false) -> String {
        if complete {
            return value.formatted(Date.FormatStyle(date: .complete, time: .standard, locale: locale))
        }
        return value.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))
    }

    func quotaTitle(_ source: String) -> String {
        guard self != .english else { return source }
        // Keep server-supplied limit names intact; only translate the generated period.
        if let separator = source.range(of: " · ", options: .backwards) {
            return String(source[..<separator.upperBound]) + quotaTitle(String(source[separator.upperBound...]))
        }
        for (suffix, translated) in [("-day", "天"), ("-hour", "小时"), ("-minute", "分钟")] {
            if source.hasSuffix(suffix), let count = Int(source.dropLast(suffix.count)) {
                return "\(count) \(translated)"
            }
        }
        return text(source)
    }

    func message(_ source: String) -> String {
        guard self != .english else { return source }
        if let translated = Self.chinese[source] { return translated }
        if let separator = source.range(of: " failed. ") {
            return text(String(source[..<separator.lowerBound])) + "失败。" + message(String(source[separator.upperBound...]))
        }
        let prefix = "Codex is still using this environment (PID "
        let suffix = "). Close Codex or its CLI and retry."
        if source.hasPrefix(prefix), source.hasSuffix(suffix) {
            let pids = source.dropFirst(prefix.count).dropLast(suffix.count)
            return "Codex 仍在使用此环境（PID \(pids)）。请关闭 Codex 或其 CLI 后重试。"
        }
        return source
    }

    private static let chinese: [String: String] = [
        "Settings": "设置", "Language": "语言", "Add Account": "添加账号", "Quit": "退出",
        "Refreshing…": "刷新中…", "Refreshing accounts": "正在刷新账号",
        "Refresh all accounts": "刷新所有账号", "Add your Codex accounts": "添加你的 Codex 账号",
        "Sign in once to view usage and switch accounts.": "登录后即可查看额度并切换账号。",
        "Cancel": "取消", "Dismiss": "关闭提示", "Recover Interrupted Operation": "恢复中断的操作",
        "Sign In": "登录", "Switch": "切换", "Remove Account": "移除账号",
        "The current account cannot be removed": "无法移除当前账号", "Account actions": "账号操作",
        "Actions for %@": "%@ 的操作", "Unavailable": "无法获取", "Sign in required": "需要重新登录",
        "Current": "当前", "Current account": "当前账号", "Plan unavailable": "无法获取套餐",
        "Weekly": "每周", "Daily": "每日", "Primary window": "主要额度周期", "Secondary window": "次要额度周期",
        "%@%% left": "剩余 %@%%", "Resets %@": "%@ 重置", "Reset time unavailable": "无法获取重置时间",
        "%d reset available": "%d 次重置可用", "%d resets available": "%d 次重置可用",
        "0 resets available": "0 次重置可用", "Reset count unavailable": "无法获取重置次数",
        "Next known expiry": "已知最近到期", "Next expiry": "最近到期", "Expires": "到期时间",
        "Expired": "已到期", "Expiry unavailable": "无法获取到期时间", "Does not expire": "不会过期",
        "Reset %d": "重置卡 %d", "Used": "已使用", "In use": "使用中", "Status unknown": "状态未知",
        "Some reset details are unavailable.": "部分重置卡明细无法获取。",
        "Reset details unavailable": "无法获取重置卡明细", "No reset details reported": "未返回重置卡明细",
        "Show reset details": "展开重置卡明细", "Hide reset details": "收起重置卡明细",
        "Weekly reset": "每周重置卡", "Bonus reset": "额外重置卡",
        "Codex is not running": "Codex 未运行", "Current account unknown": "当前账号未知",
        "Current account is not added": "当前账号尚未添加", "Working…": "处理中…",
        "Switching account…": "正在切换账号…", "Waiting for sign-in…": "等待登录…",
        "Waiting for official sign-in…": "等待官方登录…", "Removing account…": "正在移除账号…",
        "Recovering…": "正在恢复…", "Refreshing accounts…": "正在刷新账号…",
        "Checking the target account…": "正在检查目标账号…",
        "Switch failed; the previous environment was restored.": "切换失败，已恢复之前的环境。",
        "Recovery completed. Refresh accounts before continuing.": "恢复完成，请刷新账号后继续。",
        "Prepare account switch": "准备切换账号", "Switch account": "切换账号", "Sign in": "登录",
        "Remove account": "移除账号", "Save account details": "保存账号信息", "Refresh accounts": "刷新账号",
        "Recovery": "恢复操作", "Migration": "迁移", "Migration already completed.": "迁移已完成。",
        "The operation could not be completed.": "无法完成操作。",
        "Account data could not be saved safely. Existing data was kept.": "无法安全保存账号数据，已保留原有数据。",
        "Switchboard could not access its Keychain items. Allow access and retry.": "Switchboard 无法访问钥匙串，请允许访问后重试。",
        "Another account operation is running.": "另一项账号操作正在进行。",
        "An interrupted operation needs recovery. Click Recover before continuing.": "有中断的操作需要恢复，请点击“恢复中断的操作”后继续。",
        "The expected account could not be verified. The switch was not accepted.": "无法确认目标账号，切换未被确认成功。",
        "Sign in again with this account before switching.": "请重新登录此账号后再切换。",
        "A Codex process is still using the shared Codex environment. Close it and retry.": "仍有 Codex 进程使用共享环境，请关闭后重试。",
        "Close Codex Switchboard Preview before using the regular app.": "请先关闭 Codex Switchboard Preview，再使用正式版。",
        "The current Codex environment could not be identified. Close Codex and retry.": "无法识别当前 Codex 环境，请关闭 Codex 后重试。",
        "Switchboard requires effective file-based login storage. Managed policy was not changed.": "Switchboard 需要使用文件保存登录状态，未修改管理员策略。",
        "Codex could not complete the request. Refresh and try again.": "Codex 无法完成请求，请刷新后重试。",
        "Codex rejected the request. Existing account and chat data have been kept.": "Codex 拒绝了请求，已保留原有账号和聊天数据。",
        "This request is incompatible with the installed Codex version.": "此请求与已安装的 Codex 版本不兼容。",
        "Codex returned an error. Refresh and try again.": "Codex 返回错误，请刷新后重试。",
        "Codex did not respond in time.": "Codex 响应超时。", "Sign in required.": "需要重新登录。",
        "The account identity has changed. Sign in with the saved email.": "账号身份已改变，请使用已保存的邮箱登录。",
        "The current account cannot be removed.": "无法移除当前账号。",
        "The current account could not be confirmed.": "无法确认当前账号。",
        "Codex desktop could not be found.": "未找到 Codex 桌面应用。",
        "Codex did not finish quitting. Try again after it closes.": "Codex 尚未完全退出，请退出后重试。",
        "Codex could not be started.": "无法启动 Codex。", "Sign in cancelled.": "已取消登录。",
        "This account has already been added.": "此账号已添加。", "Account changes could not be saved.": "无法保存账号变更。",
        "Earlier project chat history is missing or invalid. Switching was stopped; original chats have been kept.": "较早的项目聊天历史缺失或无效，已停止切换并保留原有聊天。",
        "A project chat has conflicting local copies. Switching was stopped; no chat was overwritten.": "项目聊天的本地副本存在冲突，已停止切换，未覆盖聊天。",
        "Project chats could not be shared. Your original chats have been kept.": "无法共享项目聊天，已保留原有聊天。",
        "Shared project chats require regular session files on the same local disk.": "共享项目聊天需要位于同一本地磁盘上的普通会话文件。",
        "Project chats could not be verified. Please try switching again.": "无法验证项目聊天，请重新尝试切换。",
        "Settings changed during preparation. Please try switching again.": "准备期间设置发生变化，请重新尝试切换。",
        "Shared setup could not be read. Existing settings have been kept.": "无法读取共享配置，已保留原有设置。",
        "Multiple project registrations use the same folders. Resolve the duplicates in Codex before switching.": "多个项目登记使用了相同目录，请在 Codex 中处理重复项后再切换。",
        "This account uses an OAuth credential file. Shared authorization needs a separate migration before switching.": "此账号使用 OAuth 凭据文件，请先完成共享授权迁移后再切换。",
        "Shared setup could not be verified. Please try again; your chats have been kept.": "无法验证共享配置，请重试；已保留聊天。",
        "Shared setup is being updated. Please try again.": "共享配置正在更新，请重试。",
        "A shared MCP name conflicts with an account-specific runtime service. Rename the custom MCP before switching.": "共享 MCP 名称与账号运行服务冲突，请重命名自定义 MCP 后再切换。"
    ]
}

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue = AppLanguage.english
}

extension EnvironmentValues {
    var switchboardLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}
