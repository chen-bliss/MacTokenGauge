# MacTokenGauge

A macOS menu bar app that shows how much ChatGPT, Cursor, and Claude usage is left, when each window resets, and this Mac’s battery.

macOS 菜单栏应用。用来看 ChatGPT、Cursor、Claude 还剩多少用量，每个窗口何时重置，以及这台 Mac 的电量。

The downloadable disk image is on the [Releases](https://github.com/chen-bliss/MacTokenGauge/releases) page. It is built for Apple silicon and macOS 14 or later.

可下载的磁盘映像在 [Releases](https://github.com/chen-bliss/MacTokenGauge/releases) 页面。适用于 Apple 芯片，系统需要 macOS 14 或更高版本。

## English

### What it shows

- ChatGPT usage is read from the official site on the refresh interval, using the login already saved by the ChatGPT app. A local record is used only before the site has returned a number, and it does not replace a successful official reading.
- Cursor and Claude are read when “Read official usage” is on.
- The menu bar can show text you edit, a battery icon or a battery percent, colored bars, one ring, several rings, or rings combined into one.
- Display languages follow the system, or you can pick Arabic, Chinese, English, French, Russian, or Spanish.
- Hold Command and drag the menu bar icon to place it among other apps. It can sit just to the left of Control Center. It cannot move the clock or Control Center.
- Click outside the panel, or press Esc, to close it.
- The app stays in the menu bar and does not keep a Dock icon. Open Settings from the panel. Command-Q closes the settings window and leaves the menu bar icon running. Use Quit in the panel to leave the app.
- Once ChatGPT’s 5-hour window is used up, the app waits until that window resets before asking the site again. Claude’s 5-hour window works the same way. Cursor keeps the normal interval while Auto or on-demand can still change, and waits for the monthly reset only after those are used up as well.
- Cursor’s month figure is the included budget. Auto is a separate percent, so the month can read 0% while Auto still has some left. On-demand spend appears in the panel: a percent when it has a cap, or a dollar amount when it does not.
- The battery check interval is chosen in Settings, from 1 to 30 minutes. While Low Power Mode or a low-battery warning is on, usage checks, the menu bar clock, and battery reads slow down. They return to the intervals you chose when that ends.

### Install

1. Download `MacTokenGauge-1.2.0.dmg` from Releases.
2. Open the disk image.
3. Drag **MacTokenGauge** into the Applications folder.
4. Eject the disk image.
5. Open MacTokenGauge from Applications. Its icon stays in the menu bar. It does not add a Dock icon.

### If macOS blocks the download

This copy is signed only so it can run on a Mac. Apple has not notarized it. After a browser download, macOS marks the file as quarantined. You may see one of these messages:

- “Apple could not verify MacTokenGauge is free of malware.”
- “MacTokenGauge is damaged and can’t be opened. You should move it to the Trash.”

The app is not damaged. Do not move it to the Trash. macOS shows that wording when a downloaded app has no Apple notarization.

Use any one of the following.

**Open it from the Finder**

1. In Applications, Control-click MacTokenGauge, or right-click it.
2. Choose **Open**.
3. Choose **Open** again in the dialog.

**Allow it in Settings**

1. Try to open the app once, so macOS records the block.
2. Open System Settings, then Privacy & Security.
3. Under Security, choose **Open Anyway** next to the MacTokenGauge message.
4. Confirm **Open**.

**Remove the quarantine flag in Terminal**

This does not change the app. It only clears the download marker.

```bash
xattr -dr com.apple.quarantine /Applications/MacTokenGauge.app
```

Then open MacTokenGauge as usual.

If the disk image itself will not open, clear its marker and open it again:

```bash
xattr -dr com.apple.quarantine ~/Downloads/MacTokenGauge-1.2.0.dmg
```

### Privacy

The app reads logins that are already on this Mac, and only to ask ChatGPT, Cursor, and Claude for usage. It does not write those logins back, does not rotate refresh tokens, and does not send conversation text.

### Build from source

Open `ChatGPTGauge.xcodeproj` in Xcode, choose My Mac, and run. The product name is MacTokenGauge. The project needs Xcode and macOS 14.

## 中文

### 它显示什么

- ChatGPT 使用 ChatGPT 应用已经保存的登录，按设置里的间隔向官网读取余量。只有官网还没有返回过数字时，才暂时使用本机记录。官网一旦读到过，本机记录不会再盖掉它。
- 打开“读取官网用量”后，才会读取 Cursor 和 Claude。
- 菜单栏可以显示自己编写的文字、电池图标或电量百分比、彩色横条、单环、多环，或合成一个环。
- 界面可以跟随系统语言，也可以在阿拉伯语、中文、英语、法语、俄语、西班牙语里选择。
- 按住 Command 再拖动菜单栏图标，可以把它放到其他应用图标之间，最远到控制中心的左边。时钟和控制中心不能被挤开。
- 点击面板以外的地方，或按 Esc，面板会关闭。
- 应用只留在菜单栏，不会在程序坞里常驻。设置从弹出的面板里打开。Command-Q 只关闭设置窗口，菜单栏图标继续运行。要退出应用，用面板里的“退出”。
- ChatGPT 的 5 小时窗口用尽后，会等到这次重置再向官网查询。Claude 的 5 小时窗口同样处理。Cursor 在 Auto 或按量还会变化时仍按原间隔更新，这些也都用尽后才改到月度重置时再查。
- Cursor 的“本月”是包含额度。Auto 是另一条百分比，所以本月可以显示 0%，同时 Auto 仍有剩余。按量用量会显示在面板里：有上限时是百分比，没有上限时是金额。
- 电量检查间隔在设置里选择，范围是 1 到 30 分钟。系统开启节能，或出现低电量警告时，用量检查、菜单栏时钟和电量读取都会自动放慢，结束后恢复你设置的间隔。

### 安装

1. 在 Releases 页面下载 `MacTokenGauge-1.2.0.dmg`。
2. 打开这个磁盘映像。
3. 把 **MacTokenGauge** 拖进“应用程序”文件夹。
4. 推出磁盘映像。
5. 从“应用程序”里打开 MacTokenGauge。图标会出现在菜单栏，程序坞里不会再常驻一个图标。

### 如果系统拦截了下载的文件

这一份安装包只做了本机运行所需的签名，没有经过 Apple 公证。浏览器下载之后，macOS 会给文件加上隔离标记。你可能会看到下面两类提示：

- “Apple 无法验证 MacTokenGauge 是否包含恶意软件。”
- “MacTokenGauge 已损坏，无法打开。你应该将它移到废纸篓。”

应用本身没有损坏。请不要把它移到废纸篓。没有 Apple 公证的下载文件，系统经常会用“已损坏”这句提示来拦截。

下面三种做法，用其中一种即可。

**在访达里打开**

1. 在“应用程序”里按住 Control 点 MacTokenGauge，或按右键。
2. 选择“打开”。
3. 在对话框里再点一次“打开”。

**在系统设置里允许**

1. 先尝试打开一次应用，让系统记下这次拦截。
2. 打开“系统设置”，进入“隐私与安全性”。
3. 在“安全性”一节里，找到 MacTokenGauge 的提示，点“仍要打开”。
4. 再确认“打开”。

**在终端里去掉隔离标记**

这一步不会改应用内容，只是清掉下载时附上的隔离标记。

```bash
xattr -dr com.apple.quarantine /Applications/MacTokenGauge.app
```

然后再照常打开 MacTokenGauge。

如果磁盘映像本身打不开，先清掉它的隔离标记，再打开：

```bash
xattr -dr com.apple.quarantine ~/Downloads/MacTokenGauge-1.2.0.dmg
```

### 隐私

应用只读取这台 Mac 上已经存在的登录，用来向 ChatGPT、Cursor、Claude 查询用量。它不把登录写回去，不轮换刷新令牌，也不发送对话内容。

### 从源码构建

用 Xcode 打开 `ChatGPTGauge.xcodeproj`，选择“我的 Mac”，然后运行。生成的应用名称是 MacTokenGauge。需要已安装 Xcode，系统为 macOS 14 或更高版本。
