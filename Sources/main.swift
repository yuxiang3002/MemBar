// MemBar：在選單列即時顯示記憶體用量的小工具
// 計算方式和「活動監視器」的記憶體分頁一致：已使用 = App 記憶體 + 聯動記憶體 + 已壓縮

import SwiftUI
import AppKit
import Darwin
import ServiceManagement

// MARK: - 系統記憶體

struct MemInfo {
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0          // App 記憶體
    var wired: UInt64 = 0        // 聯動記憶體（系統核心鎖住、不能被換出的部分）
    var compressed: UInt64 = 0   // 已壓縮
    var cached: UInt64 = 0       // 快取檔案，需要時隨時可以釋放
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure = 1             // 1 正常、2 偏高、4 吃緊

    var used: UInt64 { app + wired + compressed }
    var ratio: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

enum MemReader {
    private static let host = mach_host_self()
    private static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        return UInt64(size)
    }()

    static func read() -> MemInfo {
        var m = MemInfo()

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let p = pageSize
            let anon = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            m.app = (anon > purgeable ? anon - purgeable : 0) * p
            m.wired = UInt64(stats.wire_count) * p
            m.compressed = UInt64(stats.compressor_page_count) * p
            m.cached = (UInt64(stats.external_page_count) + purgeable) * p
            m.free = UInt64(stats.free_count) * p
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            m.swapUsed = swap.xsu_used
            m.swapTotal = swap.xsu_total
        }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            m.pressure = Int(level)
        }
        return m
    }
}

// MARK: - 各 App 用量

struct AppMem: Identifiable {
    let id: String
    let name: String
    let bytes: UInt64
    let processes: Int
}

enum ProcessReader {
    private static var nameCache: [String: String] = [:]

    // 同一個 App 的子程序（例如 Chrome 的一堆 Helper）合併計算
    static func topApps(limit: Int) -> [AppMem] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) * 2)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }

        var totals: [String: (bytes: UInt64, count: Int)] = [:]
        var pathBuf = [CChar](repeating: 0, count: 4096)

        for pid in pids.prefix(Int(got)) where pid > 0 {
            var info = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            // 系統帳號的程序（例如 WindowServer）讀不到，直接略過
            guard r == 0, info.ri_phys_footprint > 0 else { continue }
            guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }

            let key = groupKey(for: String(cString: pathBuf))
            let old = totals[key] ?? (0, 0)
            totals[key] = (old.bytes + info.ri_phys_footprint, old.count + 1)
        }

        return totals
            .sorted { $0.value.bytes > $1.value.bytes }
            .prefix(limit)
            .map { AppMem(id: $0.key, name: displayName(for: $0.key), bytes: $0.value.bytes, processes: $0.value.count) }
    }

    // 路徑裡第一個 .app 就是它所屬的 App；不在 .app 裡的就用執行檔本身
    private static func groupKey(for path: String) -> String {
        if let range = path.range(of: ".app/") {
            return String(path[..<range.lowerBound]) + ".app"
        }
        return path
    }

    private static func displayName(for key: String) -> String {
        if let cached = nameCache[key] { return cached }
        var name = (key as NSString).lastPathComponent
        if key.hasSuffix(".app") {
            // displayName 會給中文名稱，例如「系統設定」
            name = (FileManager.default.displayName(atPath: key) as NSString).deletingPathExtension
        }
        nameCache[key] = name
        return name
    }
}

// MARK: - 狀態

final class MemModel: ObservableObject {
    static let historySize = 90   // 每 2 秒一筆，約 3 分鐘

    @Published private(set) var info = MemInfo()
    @Published private(set) var top: [AppMem] = []
    @Published private(set) var history: [Double] = []
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        info = MemReader.read()
        top = ProcessReader.topApps(limit: 8)
        history.append(info.ratio)
        if history.count > Self.historySize { history.removeFirst(history.count - Self.historySize) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("MemBar: 設定開機啟動失敗 \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - 格式

func bytes(_ b: UInt64) -> String {
    let gb = Double(b) / 1_073_741_824
    if gb >= 1 { return String(format: "%.2f GB", gb) }
    return String(format: "%.0f MB", Double(b) / 1_048_576)
}

struct Pressure {
    let text: String
    let color: Color

    init(_ level: Int) {
        switch level {
        case 4: text = "吃緊"; color = .red
        case 2: text = "偏高"; color = .orange
        default: text = "正常"; color = .green
        }
    }
}

enum Palette {
    static let app = Color.blue
    static let wired = Color.orange
    static let compressed = Color.purple
    static let cached = Color.gray.opacity(0.55)
    static let free = Color.gray.opacity(0.18)
}

// MARK: - 介面

struct UsageBar: View {
    let m: MemInfo

    var body: some View {
        let parts: [(UInt64, Color)] = [
            (m.app, Palette.app), (m.wired, Palette.wired), (m.compressed, Palette.compressed),
            (m.cached, Palette.cached),
        ]
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(0..<parts.count, id: \.self) { i in
                    Rectangle()
                        .fill(parts[i].1)
                        .frame(width: g.size.width * CGFloat(Double(parts[i].0) / Double(max(m.total, 1))))
                }
                Spacer(minLength: 0)
            }
            .background(Palette.free)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 10)
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let cap = MemModel.historySize
            let step = w / CGFloat(cap - 1)
            let offset = CGFloat(cap - values.count) * step
            Path { p in
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: offset + CGFloat(i) * step, y: h - CGFloat(v) * h)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(height: 36)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

struct Legend: View {
    let color: Color
    let label: String
    let value: UInt64

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(bytes(value)).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

struct PanelView: View {
    @ObservedObject var model: MemModel
    @AppStorage("showPercent") private var showPercent = true

    var body: some View {
        let m = model.info
        let pressure = Pressure(m.pressure)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(bytes(m.used))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                Text(String(format: "/ %.0f GB", Double(m.total) / 1_073_741_824))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("壓力 " + pressure.text)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(pressure.color.opacity(0.18)))
                    .foregroundStyle(pressure.color)
            }

            UsageBar(m: m)

            VStack(spacing: 5) {
                Legend(color: Palette.app, label: "App 記憶體", value: m.app)
                Legend(color: Palette.wired, label: "聯動記憶體", value: m.wired)
                Legend(color: Palette.compressed, label: "已壓縮", value: m.compressed)
                Legend(color: Palette.cached, label: "快取檔案", value: m.cached)
                HStack {
                    Text("Swap 已使用").foregroundStyle(.secondary)
                    Spacer()
                    Text(bytes(m.swapUsed)).monospacedDigit()
                }
                .font(.system(size: 12))
                .padding(.leading, 14)
            }

            Sparkline(values: model.history, color: pressure.color)

            Divider()

            Text("佔用最多的 App")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 5) {
                ForEach(model.top) { a in
                    HStack(spacing: 4) {
                        Text(a.name).lineLimit(1).truncationMode(.middle)
                        if a.processes > 1 {
                            Text("×\(a.processes)").foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(bytes(a.bytes)).monospacedDigit()
                    }
                    .font(.system(size: 12))
                }
            }

            Divider()

            Toggle("選單列顯示百分比（關閉改顯示 GB）", isOn: $showPercent)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("登入時自動啟動", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
                .toggleStyle(.switch)
                .controlSize(.small)

            HStack {
                Button("打開活動監視器") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Spacer()
                Button("結束 MemBar") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 310)
    }
}

@main
struct MemBarApp: App {
    @StateObject private var model = MemModel()
    @AppStorage("showPercent") private var showPercent = true

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            if showPercent {
                Text("RAM \(Int((model.info.ratio * 100).rounded()))%")
            } else {
                Text(String(format: "RAM %.1fG", Double(model.info.used) / 1_073_741_824))
            }
        }
        .menuBarExtraStyle(.window)
    }
}
