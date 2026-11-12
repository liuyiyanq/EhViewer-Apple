# 本期执行计划：EH-1 ~ EH-6

本文件规定本期六个任务的执行顺序、步骤间的依赖和跨任务约束。每个任务的现状分析、行为契约、修复方式、验收标准都在对应的任务卡里，本文件不重复。

更新时间：2026-11-11

## 怎么用这份计划

1. 先读完本文件的"执行规则"和"跨任务约束"
2. 按"执行步骤"的顺序做，一次只做一步。开始某一步前，读完该步列出的任务卡章节
3. 任务卡是细节的唯一来源。本文件与任务卡冲突时，以任务卡的"关键决策"为准，并修正本文件
4. 每步完成后按"任务卡更新规则"回写任务卡，再开始下一步
5. 遇到任务卡和本文件都没覆盖的设计选择，停下来写进对应任务卡的"待你决定"，向用户提问，不要自行决定

## 任务卡索引

| 编号 | 任务 | 任务卡 | 本期涉及的步骤 |
| --- | --- | --- | --- |
| EH-1 | 已下载画廊翻页仍需加载 2–3 秒 | [阅读器本地图片渲染慢/TASK.md](阅读器本地图片渲染慢/TASK.md) | 1（主因 A）、2（原因 C）、3（原因 B） |
| EH-2 | 下载并发设置看起来不生效 | [下载并发不生效/TASK.md](下载并发不生效/TASK.md) | 5 |
| EH-3 | 下载失败率高，同一画廊需反复下载才能补齐 | [下载失败率高/TASK.md](下载失败率高/TASK.md) | 2（第 1 项）、5（第 2–6 项） |
| EH-4 | 下载列表分组与手动排序 | [下载列表分组与排序/TASK.md](下载列表分组与排序/TASK.md) | 3（实现要点 1、2）、6（实现要点 3–6） |
| EH-5 | 画廊标题与评论复制、评论链接跳转、下载页封面跳转 | [画廊复制与跳转/TASK.md](画廊复制与跳转/TASK.md) | 7 |
| EH-6 | 下载列表中的画廊，阅读时在线加载的页自动存入下载目录 | [阅读时补存下载页/TASK.md](阅读时补存下载页/TASK.md) | 3（第 3 项）、4（第 1、2 项） |
| EH-7 | 下载页网格视图与拖动插入排序 | [下载页网格视图/TASK.md](下载页网格视图/TASK.md) | 真机反馈后追加，不占执行步骤 |
| EH-8 | 只有图片的画廊目录被识别成分组，且无法解散 | [下载目录空分组/TASK.md](下载目录空分组/TASK.md) | 真机反馈后追加，不占执行步骤 |

六张卡的"待你决定"目前都已清空，方案均已经用户确认。

## 仓库与基线

| 项 | 值 |
| --- | --- |
| 本地路径 | 仓库根目录（即 `docs/` 的上一级） |
| origin | liuyiyanq/EhViewer-Apple（fork，公开） |
| upstream | felixchaos/EhViewer-Apple |
| 基线分支 | `v1.3.1-base`，基线提交 `b31d6be`（上游 v1.3.1） |
| 上游参考 | `4635577`（上游 main 中阅读器本地文件读取的修复），只参考思路，不 cherry-pick |

## 执行规则

- 授权：
  - 修改代码前，确认用户已授权当前这一步
  - 创建分支、提交、推送都要先得到用户确认，一次确认对应一次操作
  - 不向 upstream 推送，不合入 upstream main
- 改动范围：
  - 只改当前步骤需要的代码，不顺手重构，不改无关格式
  - 自己的改动产生的无用代码要一并清理
  - 遵循现有命名和风格，代码注释用中文
- 定位代码：任务卡和本文件中的行号以基线 `b31d6be` 为准。前面的步骤改动后行号会偏移，以函数名为准定位
- 提交：每步至少一个提交，提交信息以卡号开头，例如 `EH-1: 本地页直接读文件并后台解码`。一步涉及多张卡时，按卡分开提交
- 不在代码、日志、任务卡中写入 Cookie、账号或其他凭据
- 不新增失败日志（EH-3 关键决策 1）

## 验证环境（外部阻塞）

| 缺什么 | 影响 | 处理方式 |
| --- | --- | --- |
| 本机未安装 Xcode，只有 Command Line Tools（Swift 6.3.3） | App target 无法用 `xcodebuild` 编译和跑测试；README 中的测试命令依赖 Xcode | 用户已决定在本机安装 Xcode（项目最低 iOS 26.2，需 Xcode 26.2 或更新）。安装后可以不用 sudo，用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild ...` 指定。安装完成前，各卡"构建"验收标为"阻塞" |
| 真机与 E-H 账号 | 各卡的真机验收只能由用户执行 | 实现完成后，把需要用户执行的验收场景列给用户 |

可以尝试在 `Packages/` 下对单个 Swift package 执行 `swift build`，但未验证是否可行（依赖需要联网拉取，部分代码依赖 UIKit），不能替代 App target 编译。

测试命令（来自 README，需要 Xcode）：

```bash
xcodebuild test -project "ehviewer apple.xcodeproj" -scheme "ehviewer apple" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

macOS target 同样要编译通过（CONTRIBUTING.md 要求）。

## 跨任务约束

以下约束是排查六张卡的交叉部分后得出的，各步骤会引用编号。

- **C1 暂停必须先能停干净。** EH-4 移动正在下载的画廊采用"暂停 → 移动 → 恢复"，依赖 EH-3 第 1 项修好取消。否则旧的下载任务会继续往旧路径写文件，把移走的目录重新建出来。因此 EH-3 第 1 项排在第 2 步，EH-4 的移动排在第 6 步
- **C2 下载完成判定只有一个入口，按磁盘计数。** 现在下载结束时按 SpiderQueen 的页面状态统计（`DownloadManager.executeDownload` 末尾）。EH-6 之后阅读器也会写入页面，可能出现两种错判：下载器失败的页被阅读器补上了，整本仍被标成失败；阅读器存满后标成已完成，又被下载器改回失败。要求：
  - 新增一个按磁盘实际文件数判定完成状态的函数，`executeDownload` 收尾和 `saveWhileReading` 都调用它
  - 旧一轮下载的收尾不得写状态（EH-3 第 1 项的运行编号）
- **C3 `localGalleryDirectory` 只改一次。** 第 3 步把它改为按路径索引查目录，第 4 步在此基础上把条件改为"在下载列表中即返回目录"，不要两步各自重写
- **C4 目录路径每次用时现查。** 阅读器存页、SpiderDen 写文件时，目录都通过 DownloadManager 按 gid 解析，不长期缓存绝对路径。这样画廊被移动或在「文件」App 中改名后仍能写对位置。唯一例外是正在下载的 SpiderDen：它的目录在移动时由"暂停 → 移动 → 恢复"保证正确（C1）
- **C5 延后改名接入收尾流程。** EH-4 规定整层重新编号时，正在下载的画廊延后改名。这个"下载停止"事件必须挂在第 2 步改好的收尾流程（`finishRunning` 一带）上，不能另起一套状态
- **C6 共用函数一起改。** EH-2 的 pToken 请求去重和 EH-3 第 6 项的每页缩略图数都改 `SpiderQueen.getPToken`，在第 5 步一起做

全局必须保持（各卡"必须保持"的公共部分）：

- `.ehviewer` 文件格式不变，图片文件名格式 `%08d.ext` 不变
- 全局图片请求并发上限 5；浏览的页面和接口请求全局不超过每秒 2 次，下载取页不占这个额度（EH-3 关键决策 9）
- 旧格式 `gid-标题` 的下载目录无需改名或迁移即可识别
- 数据库中 `download.label` 字段和 `downloadLabel` 表保留，不做删除型迁移

## 执行步骤

依赖关系：

- 第 0 步不依赖其他步骤，必须在第一次给用户打包安装之前完成
- 第 1、2 步改的文件不重叠，可以并行
- 第 3 步在第 2 步之后（都改 DownloadManager）
- 第 4 步在第 1、3 步之后
- 第 5 步在第 2 步之后。它与第 3、4 步都改 DownloadManager，建议在第 4 步之后串行
- 第 6 步在第 2、3 步之后
- 第 7 步中详情页和评论部分不依赖其他步骤，随时可做；下载页封面跳转要在第 6 步之后做

### 第 0 步：检查更新改为指向本 fork（无任务卡，细节在此）

- 背景：App 内"检查更新"查的是上游仓库。上游 main 已比 1.3.1 新，安装 fork 版后会一直提示更新；用户若照提示装了上游的包且签名设置相同，会覆盖掉 fork 版（数据保留，fork 的功能丢失）
- 改动（仓库地址统一改为 `liuyiyanq/EhViewer-Apple`）：
  - `ehviewer apple/AppUpdateChecker.swift`：`releasesURL`（Releases API 地址）、`checkForUpdate` 中 `releaseURL` 的兜底地址、文件头注释中的参考链接
  - `ehviewer apple/SettingsView.swift`：「源代码」按钮的链接
- 要点：
  - 版本比较只认纯数字段（`compareVersions` 会丢弃非数字部分），所以版本号和 Release tag 都用纯数字，tag 形如 `v1.3.2`
  - fork 还没有 Release 时，接口返回 404：手动检查显示"暂无发布版本"，启动时自动检查不提示，无需额外处理
- 完成标准：手动检查更新时请求的是 fork 的地址；「源代码」打开 fork 主页

### 第 1 步：阅读器本地页直接读文件（EH-1 主因 A）

- 先读：EH-1 卡"行为与契约""修复方式 A""关键决策 2"
- 改动：`ehviewer apple/ReaderViewModel.swift` 中的 `downloadImageData`、`loadPage`
- 要点：
  - 遇到 `file://` 地址时直接读文件，读取和降采样放到后台执行，完成后回主线程写缓存
  - 保留 GIF 多帧和超大图降采样上限
  - 用 `git show 4635577` 参考上游写法，不整体搬运
- 不做：网络加载路径、预加载窗口
- 完成标准：EH-1 验收中"横向翻页""纵向滚动""部分下载缺页""GIF"四项可交给用户真机验证；构建通过（受外部阻塞时注明）

### 第 2 步：取消、收尾与下载模式时序（EH-3 第 1 项、EH-1 原因 C、C2）

- 先读：EH-3 卡原因 3、修复方式 1；EH-1 卡原因 C；本文件 C2
- 改动：
  - `Packages/EhSpider/Sources/EhSpider/SpiderQueen.swift`：`init` 中的 `setMode`、`startDownload`、`cancelAll`
  - `Packages/EhSpider/Sources/EhSpider/SpiderDen.swift`：`setMode`
  - `Packages/EhDownload/Sources/EhDownload/DownloadManager.swift`：`processQueue`、`executeDownload`、`finishRunning`、`pauseDownload`、`deleteDownload`、`saveWhileReading`
- 要点：
  - 保存 `startDownload` 的 Task 句柄，`cancelAll` 时一并取消
  - `runningGid` 改为每轮唯一的运行编号，旧一轮收尾时编号不匹配就直接退出
  - SpiderDen 在开始派发页面前就进入下载模式
  - 按 C2 新增按磁盘计数的完成判定函数，并让 `saveWhileReading` 改用它
- 完成标准：EH-3 验收中"下载中暂停""暂停后立即恢复，连续 5 次""下载中删除"三项可交用户验证

### 第 3 步：防误删、路径索引、原子写入（EH-4 实现要点 1–2、EH-1 原因 B、EH-6 第 3 项、C3、C4）

- 先读：EH-4 卡"目录与命名规则""实现要点 1、2""关键决策 5、6"；EH-6 卡修复方式 3
- 顺序：先改清除冗余和恢复下载项目（有误删风险），再做路径索引，最后改原子写入
- 改动：
  - `ehviewer apple/SettingsView.swift`：`restoreDownloadItems`、`cleanRedundancy`、`confirmCleanRedundancy`
  - `Packages/EhSpider/Sources/EhSpider/SpiderInfoFile.swift`：`scanOfflineGalleries`
  - `Packages/EhCore/Sources/EhDatabase/EhDatabase.swift`：已有的 `downloadDirname` 表及其读写函数（v2 迁移中已建表，无需新迁移）
  - `DownloadManager`：`galleryDirectory`、`getDownloadedGalleryDirectory`、`localGalleryDirectory`、`tasksFromDatabase`
  - `SpiderDen`：`getGalleryDownloadDir` 改用 DownloadManager 的解析结果，写图片处改为原子写入（`Data.write(options: .atomic)`）
  - `galleryDirectory` 的调用方，包括 `DownloadsView.swift` 中的存储统计和行内路径
- 要点：
  - 画廊身份只认 `.ehviewer` 中的 gid
  - 扫描根目录和一层子目录；没有 `.ehviewer` 的子目录视为分组，本步只识别、不展示
  - 旧版 SpiderDen 截断规则产生的长标题目录，要能通过扫描进入索引
  - 新下载的画廊目录名规则本步不变（不加序号）
- 完成标准：EH-4 验收中"旧下载目录升级""自建 `2024-收藏` 后清除冗余""手动移动画廊目录""恢复下载项目"可交用户验证；EH-1 验收"长标题画廊""已有的长标题旧下载目录"可交用户验证

### 第 4 步：阅读时补存在线页（EH-6 第 1、2 项、C2、C3、C4）

- 先读：EH-6 卡全部；本文件 C2–C4
- 改动：
  - `ReaderViewModel.swift`：`setupLocalGallery`、`loadPage`、`syncDownloadIfEnabled`
  - `DownloadManager`：`localGalleryDirectory`、`saveWhileReading`
- 要点：
  - 画廊在下载列表中就启用本地目录，每页加载时检查文件是否存在
  - 下载列表中的画廊，在线加载成功的页一律保存，不受「阅读时同步下载」设置影响；开启「下载原图」时不保存
  - 画廊信息从 DownloadManager 的任务中取，不依赖详情页缓存
  - 不在下载列表的画廊保持原逻辑
  - 不做阅读器与下载器的同页协调（EH-6 关键决策 2）
- 完成标准：EH-6 验收表全部可交用户验证

### 第 5 步：下载网络层与重试（EH-3 第 2–6 项、EH-2、C6）

- 先读：EH-3 卡原因 1、2、4、5、7、8 和修复方式 2–6、关键决策 2、3；EH-2 卡全部
- 本步内的顺序：
  1. 限流器重写：`Packages/EhCore/Sources/EhSettings/EhRateLimiter.swift` 改为排队放行，分浏览、下载两档优先级，排队请求可取消。先写单元测试
  2. EhAPI 增加优先级参数，默认浏览档；阅读器保持浏览档。SpiderQueen 的页面和接口请求改走 EhAPI（下载档）；图片请求复用 EhAPI 的域名前置回退；图片超时改读设置值
  3. 换节点重试：使用已解析的 `skipHathKey`，带 `nl=` 重新取页面
  4. 识别"页面打开太快"提示页，下载档整体冷却
  5. 509：停止派发剩余页，整本置为失败并通知
  6. 后台：`ehviewer apple/BackgroundDownloadManager.swift` 中 BGProcessingTask 不再提前报告完成；回到前台调用 `kickQueue`
  7. `getPToken`：按详情页去重（EH-2）并使用解析出的每页缩略图数（EH-3 第 6 项）
  8. EH-2 收尾：`SettingsView.swift` 中「并发线程」改名为「单本并发页数」并加说明（11-11 真机反馈后改为「下载线程数」，不加说明）；删除 `DownloadManager` 中未使用的 `maxConcurrent`
- 不做：画廊级并发（EH-2 关键决策 1）、失败日志
- 完成标准：EH-2、EH-3 剩余验收项可交用户验证；限流器单元测试通过（受外部阻塞时注明）

### 第 6 步：分组、排序与列表 UI（EH-4 实现要点 3–6、C1、C4、C5）

- 先读：EH-4 卡全部；本文件 C1、C4、C5
- 改动：
  - `DownloadManager`：新建、重命名、解散分组，移动画廊，重新编号
  - `ehviewer apple/DownloadsView.swift`：混排列表、文件夹行、进入分组、拖动排序、「移动到分组…」；删除标签选择栏、标签增删改、批量移动标签
  - `DownloadManager.changeLabel` 和 `startDownload` 的 `label` 参数一并删除
- 要点：
  - 序号前缀 `6 位数字_`，稀疏编号，首次排序整层编号
  - 未排序项排在已排序项之后
  - 移动正在下载的画廊走"暂停 → 移动 → 恢复"（C1）
  - 延后改名接入收尾流程（C5）
- 完成标准：EH-4 验收表剩余项可交用户验证

### 第 7 步：复制与跳转（EH-5）

- 先读：EH-5 卡全部
- 改动：
  - `Packages/EhCore/Sources/EhModels/EhURL.swift`：画廊链接解析
  - `ehviewer apple/RootView.swift`：剪贴板检测改用该解析
  - `ehviewer apple/GalleryDetailView.swift`：`headerSection`、`commentSection`、`preprocessComments`
  - `ehviewer apple/GalleryCommentsView.swift`：`commentRow`
  - `ehviewer apple/DownloadsView.swift`：`DownloadTaskRow` 封面点击（须在第 6 步之后）
- 要点：
  - 整段复制（EH-5 关键决策 2）
  - 只有 `/g/` 画廊链接在 App 内打开，其他链接交给系统浏览器
  - 详情页头部优先用加载后的 `vm.detail?.info`
- 完成标准：EH-5 验收表全部可交用户验证

## 打包与升级安装

由用户在本机用 Xcode 打包。签名工具（Sideloadly、AltStore、SideStore）安装时会用用户自己的 Apple ID 重签，所以只需产出未签名的 IPA，不需要证书。仓库里的 `deploy_ios.yml` 依赖上游作者的付费证书和 App Store Connect 密钥，不使用。

打包命令（未实际运行过，第一次打包时验证）：

```bash
xcodebuild archive -project "ehviewer apple.xcodeproj" -scheme "ehviewer apple" -destination "generic/platform=iOS" -archivePath build/EhViewer.xcarchive CODE_SIGNING_ALLOWED=NO
```

```bash
mkdir -p build/Payload && cp -R build/EhViewer.xcarchive/Products/Applications/*.app build/Payload/ && (cd build && zip -qry EhViewer.ipa Payload)
```

覆盖升级、保留旧数据的条件：

- iOS 按"签名团队 + bundle ID"判断是不是同一个 App。两者都相同才是升级，`Documents/download/` 和 `Documents/eh.sqlite` 保留；任一不同，会装成另一个 App 或安装失败
- 不得修改主 App 的 bundle ID `Stellatrix.ehviewer-apple`，也不得修改小组件的 bundle ID `Stellatrix.ehviewer-apple.EhDownloadWidget`
- 用户签名时使用与安装 v1.3.1 时相同的 Apple ID、签名工具和 bundle ID 设置。部分签名工具会改写 bundle ID，签名前先在工具里核对已安装 App 的 bundle ID
- 不新增删除型或改写型数据库迁移；旧格式下载目录原样识别（EH-4）
- 每次安装新包前，提醒用户通过「文件」App 或访达，把 `download` 文件夹和 `eh.sqlite` 备份到电脑。下载目录不在 iCloud 备份范围内

版本号与发布：

- 每次打包前更新 `MARKETING_VERSION`（主 App 和小组件保持一致）和 `CURRENT_PROJECT_VERSION`，本期定为 1.3.2（用户 11-12 确认），`CURRENT_PROJECT_VERSION` 保持 1
- 在 fork 上创建 Release（tag 与版本号一致，附 IPA）后，已安装的 App 才能检查到更新。创建 tag、Release 和上传都要用户确认

## 任务卡更新规则

每步完成后，回写涉及的每张卡：

- "当前快照"：更新日期、阶段、下一步；仓库表填入分支、提交 SHA、提交状态
- 层级表：只填有证据的层级。代码写完是"已实现"，编译和测试通过是"已本地验证"，用户真机复测后才填"已回读"
- 验收表：更新状态（未开始、通过、失败、阻塞、待人工验收），并在"证据与版本"中写明提交 SHA 和验证方式
- 有新的取舍时写入"关键决策"，并注明确认来源；需要用户拍板的写入"待你决定"后停止
- 受 Xcode 缺失影响的验收项标为"阻塞"，并在卡片"外部阻塞"表登记

全部步骤完成后，在本文件末尾追加一节"执行记录"，按步骤列出提交 SHA 和遗留事项。

## 执行记录

2026-11-11，第 0–7 步代码已全部写完，**均未提交**（工作区基于 `8858093`）。按用户要求过程中未做真机验收。

| 步骤 | 内容 | 提交 | 本地检查 |
| --- | --- | --- | --- |
| 0 | 检查更新、「源代码」链接改为 `liuyiyanq/EhViewer-Apple` | 未提交 | App 类型检查通过 |
| 1 | EH-1 A：本地页后台读盘解码（`ReaderViewModel.loadLocalImage`） | 未提交 | 同上 |
| 2 | EH-3 #1、EH-1 C、C2：每轮运行编号 + 可同步取消的 `runTask`；SpiderQueen 保存下载 Task 句柄；SpiderDen 构造时定模式、目录由 DownloadManager 传入；按磁盘计数判定完成（`diskProgress`） | 未提交 | Packages 编译通过 |
| 3 | EH-4 要点 1–2、EH-1 B、EH-6 #3：清除冗余和恢复只认 `.ehviewer` 并扫两层；`GalleryDirectoryIndex` 路径索引（`downloadDirname` 表缓存）；图片原子写入 | 未提交 | 同上 |
| 4 | EH-6 #1–2：在下载列表中即启用本地目录，每页现查；在线页自动补存（开启下载原图时不存） | 未提交 | 同上 |
| 5 | EH-3 #2–6、EH-2：限流器排队放行（浏览优先、可取消、下载冷却）；SpiderQueen 页面与接口走 EhAPI 下载档、图片走 `EhAPI.fetchDownloadImage`；换节点；"打开太快"冷却；509 停止派发；BGProcessingTask 等队列下完；回前台 `kickQueue`；`getPToken` 去重 + previewPerPage；设置改名；删 `maxConcurrent` | 未提交 | Packages 编译通过；限流器临时脚本验证通过 |
| 6 | EH-4 要点 3–6：分组新建、改名、解散，移动，拖动排序与整层编号，延后改名（C5）；文件夹与画廊混排、叠放封面；下掉标签 | 未提交 | App 类型检查通过 |
| 7 | EH-5：`EhURL.parseGalleryLink`；标题、评论长按复制；评论 HTML 转带链接文本，画廊链接 App 内打开；详情页头部用加载后信息；下载页点封面进详情 | 未提交 | App 类型检查通过；解析与渲染临时脚本验证通过 |

本地检查方式（Xcode 安装前）：

- Packages：在 `Packages/EhDownload` 下 `swift build`，覆盖 EhCore、EhNetwork、EhParser、EhSpider、EhDownload
- App target：用 CLT 的 `swiftc -typecheck -swift-version 5 -default-isolation MainActor -target arm64-apple-macos26.0`，对去掉 `#Preview` 的 App 源码副本做 macOS 类型检查，0 错误、改动文件 0 告警。iOS 专属分支（`#if os(iOS)`）未被检查

遗留事项：

- 提交：待用户确认后提交。多步改动交织在同一文件（DownloadManager、SpiderQueen 等），按卡拆分提交不现实，建议按步骤或整体一次提交，提交信息列出涉及的卡号
- 编译与测试：安装 Xcode 后编译 iOS、macOS target，在 `Packages/EhCore` 运行 `swift test`（新增 `EhModelsTests`、`EhSettingsTests`）
- 各卡"关键决策"中标为"待确认"的项需要用户确认
- 真机验收：见各卡验收表中"待人工验收"的行
- 版本号已定为 1.3.2（主 App 与小组件的 `MARKETING_VERSION` 已改，README 版本徽章同步）；Release 待用户决定

2026-11-11 补充（Xcode 26.5，位于 `~/Downloads/Xcode 2.app`，用 `DEVELOPER_DIR` 指定，不改 xcode-select）：

- `Packages/EhCore` 下 `swift test`：7 项（EhURLTests 2、EhRateLimiterTests 5）全部通过
- macOS target `xcodebuild build -destination platform=macOS CODE_SIGNING_ALLOWED=NO`：成功，改动文件无告警
- iOS：Xcode 未安装 iOS 26.5 平台组件，`generic/platform=iOS Simulator` 和 `generic/platform=iOS` 都不可用，iOS 编译与打 IPA 暂时阻塞
- 补充：安装 iOS 平台组件并重启 Mac（模拟器运行时重启后才挂载；Xcode 26 的资源目录编译即使打真机包也需要它）后，iOS 未签名 archive 成功，改动文件无告警
- 已按"打包与升级安装"的命令打出 `build/EhViewer.ipa`（3.8 MB，`build/` 已被 git 忽略）。包内 bundle ID 为 `Stellatrix.ehviewer-apple`，小组件为 `Stellatrix.ehviewer-apple.EhDownloadWidget`，版本仍是 1.3.1（build 1），未改版本号

2026-11-11 真机反馈后的修正（均未提交）：

- 下载卡住、几分钟下不了一页：下载取页不再占每秒 2 次额度，去掉"打开太快"整体冷却，单页重试改回旧版节奏（5 次，0.5 秒起翻倍），见 EH-3 关键决策 9。限流器测试同步调整，`swift test` 6 项通过
- 下载速度与页数：重新开始下载时磁盘上已有的页不再重复计数（曾出现 216/138），速度只算网络字节、按最近 5 秒计算；暂停时清零，只在下载中显示
- 右滑删除确认框：从 NavigationStack 外层挪回当前层级，位置与旧版一致
- 阅读器：已下载画廊的本地文件读不出时，失败页按钮显示"重新下载"，点击后删除坏文件、从网络重新加载并存回下载目录
- 设置项文案改回「下载线程数」，去掉说明行；评论里 href 混有引号或尖括号的链接只把其中的网址标成链接
- 下载页：未排序项排在已排序项之前，拖动排序后新下载不再沉底（EH-4 决策 14，取代决策 4）；状态筛选「下载中」「等待中」合并为「队列中」，等待中显示排队位置（EH-4 决策 15）。未编译
- 下载页新增网格视图，格子可拖到另一格上松手插入、拖到文件夹上移入分组，见 EH-7
- App 显示名称改为「EhViewer」（用户 11-12 确认大小写；Mac 菜单栏与 .app 文件名不改）：主 target 增加 `INFOPLIST_KEY_CFBundleDisplayName`，简体中文 `InfoPlist.strings` 同步；`PRODUCT_NAME`、bundle ID、scheme 不变
- 2026-11-12 用户逐条确认待定决策：各卡"待你决定"已清空；EH-1 决策 3 作废（改为"重新下载"）；EH-4 决策 7 作废，新建分组不带序号、显示在最上面（决策 16）；批量栏按钮文案改为「移入分组」
- 下载目录中只有图片、没有 .ehviewer 的画廊目录被当成空分组且无法解散，见 EH-8
- 下载列表按标签搜索：只有打开过详情页的画廊才有标签数据。用户决定忽略（后续版本不再保留该功能），不做补齐
