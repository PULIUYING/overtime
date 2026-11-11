# v4 部署与验收

## 个人台账和三种状态

同一用户以真实邮箱登录，选择 root / editor / viewer，使用对应状态的密码。root 是本人台账的管理权限，没有全站用户管理权限。

| 功能 | 管理 root | 编辑 editor | 查看 viewer |
|---|---|---|---|
| 本人记录、图片、工资面板、导出 | 是 | 是 | 是 |
| 登记、修改、上传本人图片 | 是 | 是 | 否 |
| 删除本人记录与图片 | 是 | 否 | 否 |
| 本人月度工资设置、状态密码设置 | 是 | 否 | 否 |
| 本人操作日志 | 是 | 否 | 否 |
| 其他人的任何数据或密码 | 否 | 否 | 否 |

底层为三种状态分配独立 Supabase Auth 身份，通过受保护的 profiles.owner_id 关联到同一本人台账。用户界面只输入真实邮箱，不需要知道内部登录别名。模式不是前端随意切换的变量，修改网页代码不能提权。首次只有管理状态；设置另外两套密码后启用编辑/查看状态。

## 新项目安装

1. 创建 Supabase 项目。SQL Editor 中运行 **install.sql 一次**，它在一个事务内完成建表、个人隔离策略、私有图片桶和日志触发器。不要额外运行旧 schema.sql 或其他 migration。
2. 在 Authentication → Users 创建你的真实邮箱账号、管理密码并自动确认邮箱。首次账号自动映射为本人 root。关闭公开注册，配置密码最短 12 位。以后若新增其他人，由项目维护者在控制台创建其真实账号，他们自动获得各自独立的台账。
3. config.js 填 Project URL 和 Publishable key。服务端 service_role / secret 密钥、数据库密码不写入前端。
4. 部署两个 Edge Functions：mode-login 和 manage-users。Supabase CLI 示例：

```sh
supabase login
supabase link --project-ref 你的项目标识
supabase functions deploy mode-login --no-verify-jwt
supabase functions deploy manage-users --no-verify-jwt
```

托管 Supabase 自动提供函数所需 SUPABASE_URL、SUPABASE_SERVICE_ROLE_KEY 环境变量。关闭网关 JWT 校验是为了允许登录端点及兼容 publishable key；mode-login 仍调用 Supabase Auth 验证密码，manage-users 验证用户令牌、本人 root 身份并重新核对管理密码。

5. 部署前端十个文件：index.html、style.css、config.js、app.js、accounts.js、holidays.js、photos.js、companies.js、payroll-core.js、payroll.js。
6. 管理状态登录 → 账号设置 → 分别配置编辑密码和查看密码。三种状态都使用同一真实邮箱，不能只改选择框而不重新认证。
7. 数据面板底部展开本月参数，填工资、五险一金和前期累计税务数据，核对后保存。未配置时金额显示“—”。

## 从 v3 升级到 v4

备份后运行 migration-v4.sql 一次，再上传全部十个前端文件。本次无需修改两个 Edge Functions。图片桶单文件限额调整到 20 × 1024 × 1024 字节；如 Supabase 项目全局限额更低，也需调高到至少 20MB。

旧记录和工资设置归入本人“默认公司”，不会丢弃旧记录。root 可以重命名它。不同公司的同一个月份独立保存工资设置与前期累计数据，避免把不同扣缴单位混算。记录可以在编辑时更正到本人的另一家公司，图片随记录归属一起变更。

登录认证后若有多家公司，会弹出选择窗口；仅一家公司自动进入；新账号没有公司时提示 root 先添加。录入页必选所属公司，默认当前公司。所有状态都可以切换本人的公司，但只有 root 能添加和改名；当前不提供公司删除。

日志仍汇总本人全部公司和账号事件，并标注公司，只有本人 root 可看；迁移前日志显示“账号 / 历史”。记录 CSV、带图 HTML、工资 CSV 都标明公司并在文件名中加入公司名称。

单张图片允许 20MB，带图 HTML 的总图片容量限制仍是 50MB，避免手机内存不足；超过时可分别保存原图。这两个限制含义不同。

验收：创建甲乙两家公司，分别登记与设置工资；反复切换确认面板不串数据；登录多公司选择；登记选择公司；检查所有导出名称；验证 20MB 边界与跨用户公司 ID 写入被拒绝。真实云端上传与数据库约束仍需配置后联调。

## 旧 v2 升级

先备份并暂时停止旧前端访问，再依次执行 migration-v3.sql 和 migration-v4.sql 各一次。旧 profiles 的每个真实账号变为自身台账 root，记录按原 user_id 隔离，不再共享。旧共享时期由别人登记的记录仍归原创建账号，不会猜测重新分配。旧记录的计薪类型均标记待确认。

**必须同时重新部署新版 manage-users，并新增 mode-login，再替换前端后开放访问。** 旧版 manage-users 有全局管理语义，不能保留旧函数配合新版使用。若旧项目已存在内部状态别名，不要重复运行迁移，先检查数据。已部署 v1、未执行 v2 的项目应先按顺序执行 migration-v2.sql、storage.sql、migration-v3.sql、migration-v4.sql，并在全部完成前停止访问。

## GitHub Pages / 其他服务器

GitHub 创建公开仓库，十个前端文件上传根目录；Settings → Pages → Deploy from a branch → main → / (root)，等待部署。

Nginx、Apache、IIS、宝塔或其他静态托管直接放置上述文件即可，也支持子目录。公网使用 HTTPS。Docker 方式：

```sh
docker compose up -d --build
```

本机访问 http://localhost:8080，外网经反向代理配置 HTTPS。这个 Docker 只包含网页，不包含完整后端；其他服务器版本仍连接同一 Supabase。完全自托管需要另行部署 Supabase 各后端服务。

## 日志

记录增删改、月度工资参数写入由数据库触发器记录；私有图片上传删除由 Storage 元数据触发器记录；密码变更由 Auth 数据库触发器记录。网页登录成功由登录函数记录。密码设置操作另记事件，不记录密码、哈希、令牌或图片内容。

日志仅本人 root 可查询，客户端没有插入/更新/删除权限。编辑/查看状态自己的操作也会产生供本人 root 查看的日志。不是全站管理员日志，不展示其他人的内容。失败登录不记录到用户台账；直接绕过网页登录函数调用 Auth 的登录事件应查 Supabase Auth 日志，当前台账不作为完整安全审计系统。项目数据库管理员仍有维护权限。日志目前不提供自动清理策略。

## 节假日、图片与导出

节假日来源 [holiday-cn](https://github.com/NateScarlet/holiday-cn)，汇集国务院年度放假调休通知，并非政府官方 API。打开录入、切换日期会同步，页面开启期间每 6 小时检查；12 月同时检查次年。网络失败或年度未公布会提示人工确认，不更改已有记录。标准工时按钮需要完整年度数据，否则保留人工填写。

放假日不等同于法定计薪日，所以每条记录另设计薪类型；旧记录默认待确认，不自动套用 3 倍工资。详见 CALCULATION.md。

图片先保存记录，再在明细点“图片”。每张 JPG/PNG/WebP 最多 20MB，存于私有桶，读取生成 10 分钟签名链接；已签名的链接在有效期内仍可读取。删除含图片记录前，root 先删除附件。CSV 不嵌图，含图片 HTML 导出可离线打开或打印 PDF，单次累计图片限 50MB。工资面板另有工资 CSV 导出。导出文件离开系统后不受账号权限保护。

## 必须在真实项目执行的验收

1. 创建 A、B 两个真实用户，分别设置三种状态。A 的每种状态均只能读取 A 的记录、图片和工资；即使以 B 的 root 登录也不能按 A 的 ID 查询、修改或获取签名图片。
2. A 编辑状态能登记修改上传，不能删除；查看状态不能写入。调用 API 而不通过按钮也应被数据库拒绝。
3. 管理状态只能设置自己的模式密码，不接受外部 target 用户 ID；编辑和查看调用 manage-users 返回 403。
4. 各种操作写日志，A root 可读，A editor/viewer 及 B root 不可读或修改 A 日志。
5. 登录默认数据面板和当前月份；每日时长、比例、工资算例与工资条核对。未确认计薪、未填参数应明确提示。
6. 手机上传图片，电脑刷新读取；断网不能假装保存成功；导出图片 HTML 离线可看。
7. 日历同步成功、失败及跨年；GitHub Pages、另一服务器读取相同后端。

当前交付已做 JavaScript 语法、工资计算边界及源代码检查；没有真实云端凭据，SQL 执行、Edge Function 部署、RLS 多身份隔离和 Docker 环境仍需验收。
