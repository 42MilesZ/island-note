# Island Note 隐私政策

更新日期：2026 年 10 月 8 日。开发者：hanyu zhu。

## 本机笔记

Island Note 默认在你的 Mac 上保存笔记，无需注册账号。应用不会自动向开发者发送笔记，也没有开发者运营的笔记服务器。Mac App Store 版本默认将笔记保存在应用的沙盒容器内。你可以在设置中更改保存位置，或打开已有的 Markdown、纯文本文件并保存回原文件。商店版读写沙盒以外的文件，需要你通过系统文件选择器授权；访问授权保存在本机，以便下次继续使用。直装版本也支持你配置的本机文件。应用设置用于保存功能开关。界面语言跟随系统。

## 可选的 Flomo 同步

Flomo 同步默认关闭。开启时会先说明数据用途；连接自己的 Flomo 账号后，应用通过 HTTPS 将这份笔记发送给 Flomo，并读取已连接的备忘录以完成双向同步。你使用查找功能时，搜索词也会发送给 Flomo。请求会携带用于授权的个人令牌及对应备忘录的标识。已有连接在重新开启后会按此前的同步或暂停状态恢复。

令牌保存在 macOS 钥匙串中，不写入笔记或诊断报告。为防止同步丢失内容，应用在本机保留同步状态、版本比较所需的内容和替换前的备份。开发者不会接收这些同步内容。Flomo 是独立的第三方服务，其数据存储、保留和删除规则请查阅 [Flomo 隐私政策](https://help.flomoapp.com/privacy.html)。

关闭 Flomo 开关会停止新的同步请求；已发出的请求可能完成。两端笔记、已保存的令牌和本机备份会保留，关闭开关不会删除 Flomo 上的内容。你可以在 Flomo 管理或删除远端笔记，并在 macOS 钥匙串访问中删除已保存的令牌。

## 本机诊断

诊断默认关闭。开启后，应用记录手势阶段、面板尺寸、交互与焦点状态、事件时间、应用及系统版本，用于排查交互问题。最近 300 条事件保存在本机，不包含笔记正文、文件名、账号信息、令牌、截图或其他应用的内容。高频手势增量会采样记录。

在设置中关闭诊断会停止记录，已有记录会保留；选择清除记录会删除本机诊断文件。导出报告会将副本保存到你选择的位置，不会自动上传。你主动向开发者发送报告时，报告中的诊断信息会用于处理你反馈的问题，请勿附带令牌或私人笔记。已经导出的副本需要自行删除。

## 数据保留与控制

笔记和本机同步备份会保留，直到你主动修改或删除相应文件。卸载应用不保证删除本机数据、系统备份或钥匙串中的令牌。删除数据前请保留需要的笔记；如果使用系统备份或其他备份服务，也需要单独管理其中的副本。

应用没有广告、第三方分析或用于跨应用追踪的功能。开启 Flomo 同步不影响你关闭本机诊断；两项功能分别控制。

## 政策更新与联系

政策发生变化时，我们会更新本页的日期。新增的数据用途会在相关功能中说明，并在需要时征求你的同意。你可以通过 [Island Note 项目问题反馈](https://github.com/42MilesZ/island-note/issues) 联系开发者。请在公开反馈中避免提交笔记正文、令牌或其他个人信息。

---

# Island Note Privacy Policy

Updated October 8, 2026. Developer: hanyu zhu.

## Local notes

Island Note saves notes on your Mac by default and does not require an app account. It does not automatically send notes to the developer, and the developer does not operate a note server. The Mac App Store version saves notes in its sandbox container by default. In Settings, you can change the save location or open an existing Markdown or plain-text file and save changes back to it. Access to files outside the store app’s sandbox requires your authorization through the system file picker. This authorization stays on your Mac so the app can reopen the file later. The direct-distribution version also supports local files you configure. App preferences store your feature choices. The interface language follows your system.

## Optional Flomo sync

Flomo sync is off by default. Enabling it first explains how data is used. After you connect your own Flomo account, the app sends this note to Flomo over HTTPS and reads the linked memo to synchronize changes in both directions. Memo searches send your search terms to Flomo. Requests include your personal authorization token and the relevant memo identifiers. An existing connection keeps its previous syncing or paused state when you enable the feature again.

The token is stored in macOS Keychain, not in notes or diagnostic reports. To protect against content loss, the app keeps sync state, comparison versions and backups before replacements on your Mac. The developer does not receive this sync content. Flomo is an independent third-party service. Its storage, retention and deletion practices are described in the [Flomo Privacy Policy](https://help.flomoapp.com/privacy.html).

Turning off Flomo stops new sync requests. Requests already sent may finish. Both notes, the saved token and local backups remain; turning off the feature does not delete content from Flomo. You can manage or delete remote notes in Flomo and remove the saved token using macOS Keychain Access.

## Local diagnostics

Diagnostics are off by default. When enabled, the app records gesture phases, panel dimensions, interaction and focus states, event times, and app and operating-system versions to investigate interaction problems. The most recent 300 events stay on your Mac. They do not include note text, file names, account details, tokens, screenshots or other apps' content. High-frequency gesture deltas are sampled.

Turning diagnostics off in Settings stops recording and retains existing records. Clear Records deletes the local diagnostic files. Export Report saves a copy to the location you choose and does not upload it. If you choose to send a report to the developer, its diagnostic information is used to address your report. Do not attach tokens or private notes. Delete exported copies separately when you no longer need them.

## Retention and controls

Notes and local sync backups remain until you edit or delete the corresponding files. Uninstalling the app does not guarantee removal of local data, system backups or Keychain tokens. Keep any notes you need before deleting data. Copies in system or other backup services must be managed separately.

The app does not include advertising, third-party analytics or cross-app tracking. Flomo sync and local diagnostics are controlled independently.

## Updates and contact

We update the date on this page when the policy changes. New data uses will be explained in the relevant feature, with consent requested where needed. Contact the developer through [Island Note project issues](https://github.com/42MilesZ/island-note/issues). Avoid posting note text, tokens or other personal information in public reports.
