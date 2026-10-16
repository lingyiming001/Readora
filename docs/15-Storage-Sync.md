# 15 · 本地存储与 iCloud 同步

## 文件布局与导入事务

```text
Application Support/Readora/
├── Stores/Library.sqlite           # Core Data 及关联 WAL/SHM 由框架管理
├── Books/<contentHash>/original.*  # 原文，不写绝对路径进云端
├── Staging/<importID>/             # 尚未提交的临时副本
├── Journals/<importID>.json        # 跨文件/数据库恢复凭证
└── Backups/                        # 用户触发的备份，提供清理入口
Caches/Readora/
├── Publications/<hash>/<version>/  # 解压和规范正文，可删除重建
├── Covers/                        # 缩略图
└── Search/                        # 独立全文索引
```

导入在 security-scoped 访问范围内协调复制，确保 stopAccessing 与 defer 配对；文件提供者尚未下载时显示等待，可取消。复制期间计算 hash，校验格式后 journal 记录 validated，原子 rename 至最终目录，再数据库事务写 Book/LocalBookAsset，最后清理 journal。崩溃后扫描 journal：已落文件未落库则补提交或移回隔离；已落库则验证 hash 并完成清理。不得把「两个写入」误称为跨介质原子事务。

并发同 hash 经 ImportActor 串行 commit；两个设备导入相同字节可有不同 UUID，元数据合并按 hash 建 canonical book 映射，重挂进度/笔记后 tombstone 重复记录，保留修复日志。相同标题不同 hash 永不自动合并。

## 元数据同步

MVP 完全本地；V1 用户选择后将业务元数据放入预先设计的 CloudKit-compatible store，由 NSPersistentCloudKitContainer 管理镜像；本地资产状态、缓存和播放意图在非镜像 store。开启/关闭同步需要受控重载 store，不能在未验证情况下临时切换参数并保证无损；上线前测试账户切换与迁移，必要时使用新 store 复制并备份。

CloudKit 私有库仅当前 iCloud 用户；未登录、受限、网络断开、配额满均返回状态提示，本地继续使用。eventChangedNotification 与持久化历史驱动刷新，展示「等待系统同步/最近成功时间/失败重试」，不虚构精确同步百分比或 SLA。[Apple TN3163](https://developer.apple.com/documentation/technotes/tn3163-understanding-the-synchronization-of-nspersistentcloudkitcontainer) 说明系统负责同步任务的调度。

云端兼容模型属性须有默认值或可选、关系可选/有 inverse，不依赖 unique constraints、ordered relationship 或跨 store relationship。外键用业务 UUID；derived chapter/index 可本地重建，不镜像全书文本。

## 可实现的冲突策略

| 数据 | 存储与合并规则 |
|---|---|
| 阅读/朗读检查点 | 每设备/会话独立记录，counter 只在同设备排序；跨设备最后活动时间是建议，不是可靠全局因果序；并发时展示两端位置 |
| 书名/收藏/设置 | 低风险标量可接受容器合并后结果，保留本地历史供撤销；不声称框架提供任意 CRDT |
| 笔记 | 每次修改创建不可变 AnnotationRevision（revisionID/baseRevisionID/body）；同 base 分叉保留两版，用户合并再创建新 revision |
| 书架成员 | membership 增删事件保留 operationID；同 logical key 去重；删除 tombstone 优先于未明确恢复的旧增加 |
| 删除/恢复 | 删除带 tombstone 与 deletionID；恢复显式引用该 deletionID；离线旧写不能直接复活已删书 |

不可变 revision/事件是为重要编辑避免被容器字段合并吞掉；投影需幂等、可重建。Core Data merge policy 本身不能完成上述语义。设备时钟偏移不能靠 updatedAt 完全解决；时钟异常时保留选择入口。Schema 变更以增量新增字段为主，旧客户端兼容读取，不依赖云端删除字段。

## 原始文件同步（V1.1）

单独选择「通过 iCloud Drive 同步书籍」，明确占用用户 iCloud 容量。文件放应用 ubiquity container 的受控路径，以 hash 命名，NSFileCoordinator 协调访问；远端文件未落地先下载到暂存，校验 hash 后登记 LocalBookAsset。元数据 record 只引用 hash，不把大文件塞进 Core Data 二进制属性。

队列建议同时上传/下载各 1，默认 Wi-Fi 大文件，低电量/后台由系统调度；可暂停重试，不承诺后台完成时间。展示本地/待上传/云端可下载/下载中/冲突/失败。用户删除本地下载与删除全库是两个动作，前者保留云端和笔记。两通道最终一致，书库允许元数据先到、文件后到。

## 备份、恢复与隐私

备份包含 manifest（schemaVersion、导出时间、文件 hash）、原文、元数据 JSON、批注；可选排除原文减小体积。恢复先校验、预览合并/新建，不直接替换打开中的 SQLite。导出不是同步；iCloud 也不等于历史备份。账户退出时询问是否保留本地副本，按账户隔离 store，不能把 A 用户未同步编辑写入 B 用户库。

回收站 30 天是应用逻辑保留期，彻底清理在在线设备逐步传播；不设置短期自动清除 tombstone 导致长期离线设备复活记录。未来清除需引入设备水位或账户重建机制。加密保护遵循系统账户和容器能力，不宣称所有 CloudKit/iCloud Drive 数据默认端到端加密，发布前核验具体配置与用户设置。
