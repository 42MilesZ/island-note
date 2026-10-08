# Island Note 使用与支持

Island Note 是 macOS 屏幕顶部的笔记工具，需要 macOS 14 或更高版本。

## 开始使用

1. 把鼠标移到屏幕顶部的黑色区域，展开笔记并输入。内容会自动保存在本机。
2. 从输入框顶部的空白横条拖出，笔记会成为保持置顶的悬浮面板。拖动边缘调整大小，或用触控板缩放手势连续调整。
3. 拖回顶部附近并松手，面板吸附回去。按 Esc 可以回到顶部并收起。
4. 通过右键菜单或按 ⌘, 打开设置。界面语言跟随系统，支持简体中文与英文。

## Markdown 与目录

输入标题、粗体和列表时，编辑器会显示排版。较长的笔记可通过标题目录跳转。普通编辑与收起都不会清空正文。

## 可选 Flomo 同步

Flomo 默认关闭。在设置中开启，阅读数据用途说明，然后选择连接与管理。需要自己的 [Flomo MAX 个人令牌](https://help.flomoapp.com/advance/mcp/token.html)，令牌保存在 macOS 钥匙串中。

留空备忘录字段会新建一份专用备忘录；连接已有备忘录时可以搜索并选择。两端内容不同时，先检查完整版本再决定如何合并或替换。不要把私人令牌发送到公开反馈中。

同步支持段落、标题、粗体和普通列表。表格、代码块、复选框、引用、Markdown 链接与图片、wiki 链接等格式会暂停同步，正文仍在本机保存。网络中断时保留待同步内容；出现提醒时点击右上角状态点查看原因。

关闭 Flomo 会停止新请求，两端笔记、令牌和本机备份保留。基本本机笔记功能不需要 Flomo 账号或联网。

## 反馈问题

在设置中开启本机诊断，重现问题后导出报告。报告不会自动上传；关闭诊断后保留旧记录，清除记录只删除本机诊断文件。

通过 [项目问题反馈](https://github.com/42MilesZ/island-note/issues) 描述发生了什么、预期结果、应用版本及 macOS 版本。请避免在公开反馈中上传私人笔记、令牌或包含私人信息的截图。保存失败时保留编辑器中的文字，并检查红色状态提示后再退出。

[隐私政策](privacy-policy.md)

---

# Island Note Help and Support

Island Note is a note panel at the top of your Mac screen. It requires macOS 14 or later.

## Getting started

1. Hover over the black area at the top of the screen to open your note. Text saves automatically on your Mac.
2. Drag the empty header away from the top to create a floating panel that stays above other windows. Resize its edges or use a trackpad magnification gesture.
3. Drag back near the top and release to dock. Press Esc to return and collapse.
4. Open Settings from the context menu or with ⌘,. The interface follows your system language, with English and Simplified Chinese supported.

## Markdown and the outline

Headings, bold text and lists display as you write. Use the heading outline to navigate longer notes. Editing and collapsing retain your note text.

## Optional Flomo sync

Flomo is off by default. Enable it in Settings, read the data-use notice and choose Configure Flomo. You need your own [Flomo MAX personal token](https://help.flomoapp.com/advance/mcp/token.html), stored in macOS Keychain.

Leave the memo field empty to create a dedicated memo, or search for and select an existing memo to connect it. When the copies differ, review both complete versions before choosing to merge or replace them. Keep personal tokens out of public reports.

Sync supports paragraphs, headings, bold text and ordinary lists. Tables, code blocks, checkboxes, blockquotes, Markdown links and images, and wiki links pause sync; your source still saves locally. Connection failures retain pending work. Click the status indicator to review a warning.

Turning Flomo off stops new requests and retains both notes, the token and local backups. Core local-note features need neither a Flomo account nor an internet connection.

## Reporting an issue

Enable local diagnostics in Settings, reproduce the problem and export a report. Nothing uploads automatically. Turning recording off keeps existing records; Clear Records deletes the local diagnostic files.

Use [project issues](https://github.com/42MilesZ/island-note/issues) to describe the problem, expected result, app version and macOS version. Keep private notes, tokens and screenshots containing personal information out of public reports. If saving fails, keep your text in the editor and check the red status warning before quitting.

[Privacy Policy](privacy-policy.md)
