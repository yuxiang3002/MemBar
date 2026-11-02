# MemBar

macOS 選單列小工具，即時顯示記憶體用量、記憶體壓力和最吃記憶體的 App。

單一 Swift 檔，只要 Xcode 命令列工具就能編譯，不需要完整的 Xcode。

## 功能

- 選單列顯示用量百分比或 GB
- 已使用量的算法和「活動監視器」相同：App 記憶體 + 聯動記憶體 + 已壓縮
- 用量長條拆成 App、聯動、已壓縮、快取檔案
- 記憶體壓力（正常、偏高、吃緊）與 Swap 用量
- 近 3 分鐘的用量曲線
- 佔用最多的 8 個 App，同一個 App 的子程序會合併計算
- 開機自動啟動、一鍵打開活動監視器

## 怎麼判斷記憶體夠不夠

看壓力和 Swap 比看百分比準。macOS 會把閒置記憶體拿去當快取，用量高很正常，壓力維持綠色就沒問題。壓力轉橘紅、Swap 持續增加，才代表記憶體真的不夠。

## 需求

- macOS 13 以上
- Xcode 命令列工具：`xcode-select --install`

## 安裝

```
git clone https://github.com/yuxiang3002/MemBar.git
cd MemBar
bash build.sh
```

或直接雙擊 `安裝MemBar.command`。

如果是下載 Releases 裡編好的版本，第一次開啟前要在終端機執行：

```
xattr -cr /Applications/MemBar.app
```

## 限制

App 清單只看得到你自己帳號執行的程式，WindowServer、kernel_task 等系統程序讀不到，所以清單加總會比總用量少。

## 授權

MIT
