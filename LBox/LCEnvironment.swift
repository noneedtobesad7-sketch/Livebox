import Foundation

/// 判断当前 Livebox 是不是跑在 LiveContainer 的多任务（LiveProcess 扩展）里。
///
/// 单任务时 LC 进程自己就是 guest，`TweakLoader/UIKit+GuestHooks.m` 会把发往
/// `livecontainer://install` 的请求直接拦下（只弹“重启后安装”），所以只有多任务里
/// 那个 URL 才会被宿主收到并弹出安装框。
enum LCEnvironment {
    /// 多任务时 guest 跑在 LiveProcess 扩展进程里，只有这个进程有 LP_HOME_PATH。
    static var isMultitask: Bool { getenv("LP_HOME_PATH") != nil }

    /// 备选判定：LC 注入的 `+[NSUserDefaults isLiveProcess]`。
    static var isLiveProcess: Bool {
        guard let cls = NSClassFromString("NSUserDefaults") else { return false }
        let selector = NSSelectorFromString("isLiveProcess")
        guard cls.responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        let imp = cls.method(for: selector)
        return unsafeBitCast(imp, to: Fn.self)(cls, selector)
    }

    /// 只有多任务才能就地弹 LC 安装框；单任务点了只会被 guest hook 拦下。
    static var canInstallInPlace: Bool { isMultitask || isLiveProcess }

    /// 一段可直接贴给用户的步骤，引导/日志共用。
    static var guideText: String {
        L10n.t("请先在 LiveContainer 里长按 Livebox 选「多任务」；\n或在 LC 设置 › Multitask 打开「Auto Launch in Multitask Mode」，之后点图标即为多任务。",
               "Long-press Livebox in LiveContainer and choose Multitask; or enable Auto Launch in Multitask Mode in LC Settings › Multitask.")
    }
}
