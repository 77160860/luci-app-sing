
## 说明

用于 OpenWrt 的 sing-box LuCI 轻量管理面板，支持 JSON 配置编辑、上传下载配置、自定义下载核心、服务控制等。

<img width="1846" height="1307" alt="1" src="https://github.com/user-attachments/assets/cf6c7940-6ffe-41c4-a18a-d8bb8486b347" />

<img width="1843" height="1373" alt="2" src="https://github.com/user-attachments/assets/e34ce238-0d06-488f-b0f5-3569f597c1a2" />

## 功能

- 查看sing-box版本、运行状态、配置路径。
- 启动、停止、重启服务，设置开机启动。
- 粘贴、编辑、格式化和校验 JSON 配置。
- 支持在线下载配置及上传本地配置文件。
- 支持自定义核心地址下载更新核心服务。

## 安装

从 [Releases](https://github.com/77160860/luci-app-sing/releases) 下载安装包，上传到路由器的 `/tmp` 目录：

```sh
# APK
apk add --allow-untrusted /tmp/luci-app-sing-*.apk

# opkg
opkg install /tmp/luci-app-sing_*.ipk

/etc/init.d/rpcd restart
```

发布的 APK 未签名，安装时需要 `--allow-untrusted`。依赖为 `luci-base`、`sing-box`、`rpcd`、`jshn` 和 `jsonfilter`，由设备匹配的软件源安装。

## sing-box 服务配置

面板使用以下路径：

```text
/usr/bin/sing-box
/etc/init.d/sing-box
/etc/config/sing-box
/etc/sing-box/core.sh
```

`/etc/sing-box/core.sh` 是面板的共享后端脚本，由 rpcd 插件与后台 worker 引用。sing-box 运行时会在工作目录（启动脚本的 `-D` 参数）内生成缓存数据库 `cache.db` 与外部 UI 目录 `ui/`；`cache_file.path` 与 `clash_api.external_ui` 使用相对路径时即相对该工作目录解析。上游启动脚本的默认工作目录为 `/usr/share/sing-box`，面板安装时通过 `/etc/uci-defaults/90-luci-app-sing` 将 `sing-box.main.workdir` 迁移到 `/etc/sing-box`（仅在未设置或仍为旧默认值时；已自定义为其它路径则保持不变），使 `cache.db` 与 `ui/` 统一落在 `/etc/sing-box` 下。安装脚本在 apk 与 ipk 下都会立即执行该迁移；若此时 sing-box 已在运行，会自动重启服务以套用新工作目录。

`/etc/config/sing-box` 示例：

```uci
config sing-box 'main'
        option enabled '1'
        option conffile '/etc/sing-box/config.json'
        option workdir '/etc/sing-box'
        option log_stderr '1'
```

| 选项         | 用途                                               |
| ------------ | -------------------------------------------------- |
| `enabled`    | 服务启动开关，启动、重启、应用或开启自启时设为 `1` |
| `conffile`   | 面板直接读写的 JSON 配置文件，使用绝对路径         |
| `workdir`    | sing-box 工作目录，面板默认迁移为 `/etc/sing-box`  |
| `log_stderr` | stderr 日志收集选项，实际行为由设备启动脚本决定    |
| `user`       | 面板用于指定新建配置文件所有者的用户选项           |

未配置 `user` 时，面板按 root 处理新建配置文件的所有者。服务实际运行用户由已安装的启动脚本决定。

配置文件的父目录需要已存在，配置文件应为普通文件。保存现有文件时保留其所有者和权限，新建文件的权限为 0600。

**开机启动**启用 init 服务启动链接，并将 `enabled` 设为 `1`；取消勾选只禁用启动链接。

**停止**停止当前服务，不修改开机启动设置。停止命令成功返回后，等待确认进程退出。

配置路径或工作目录异常时，仍可停止服务、查看系统日志。只读账号可以查看状态、重载和复制配置、查看日志；编辑、校验和服务控制均不可用。

## 配置使用

| 操作        | 行为                                                     |
| ----------- | -------------------------------------------------------- |
| 格式化配置 | 浏览器解析 JSON，以 2 个空格缩进重新输出，只修改编辑器   |
| 校验配置    | 通过临时文件校验编辑器内容，不保存、不重启               |
| 保存并应用  | 保存、校验，通过后重启服务                               |
| 重载配置    | 从 `conffile` 重新读取内容；有未保存修改时先确认是否放弃 |

配置大小上限为 **128 KiB**，按 UTF-8 字节数计算。格式化使用 `JSON.parse` 和 `JSON.stringify`，不调用 `sing-box format`，输入必须是标准 JSON。

校验使用已安装的 sing-box 内核及服务工作目录。“校验”传入临时文件路径，完成后清理；“保存并应用”传入正式配置路径：

```sh
sing-box check -c <待校验文件> -D <workdir>
```

单独校验不会改动正式配置或服务状态。“保存并应用”先保存再校验；校验失败时显示内核错误，已保存的文件保留，服务不重启。修改错误后可再次保存并应用。

保存前会检查文件版本。如果其他窗口或 SSH 已修改文件，页面会提示重新加载，避免覆盖外部修改。

### 配置写入

配置直接写入 UCI 的 `conffile` 路径，采用同目录临时文件加原子替换，完成后清理临时文件。

保存并应用后的启动检查要求服务 PID 在约 3 秒内保持存活且不变。启动失败时显示错误，已保存配置保留，需要修改后重新应用。

## 清理缓存

在 **概览 → 维护 → 清理缓存** 后端读取已保存配置的 `experimental.cache_file`，`path` 留空时使用 `cache.db`，相对路径按 UCI 的 `workdir` 解析。

新缓存由 sing-box 启动时生成。启动失败会显示错误并尝试停止服务，旧缓存无法恢复。自启设置保持不变。

缓存安全检查使用系统自带的 `ls` 和 `/proc/self/mountinfo` 获取硬链接数及文件身份，无需安装 `stat` 或 `coreutils-stat`。读取检查信息失败时会单独提示。

## 日志

日志页通过 `logread` 读取 sing-box 系统日志，显示最近 300 行，最多 32 KiB。进入日志页立即读取一次，停留在日志页时每 2 秒更新；可通过右上角 LuCI 刷新开关暂停或恢复自动更新。

- 系统日志是否收集 sing-box 输出，取决于设备上的服务启动脚本；部分脚本使用 `log_stderr` 选项。
- JSON 中设置 `log.output` 时，页面显示文件去向；日志窗口显示的仍是系统日志。
- JSON 中设置 `log.disabled: true` 时，页面显示日志关闭提示。

面板显示日志时过滤 ANSI 颜色码。日志在内容框内滚动，并显示最近更新时间。右上角 LuCI 刷新开关同时控制服务状态与后台操作结果的定时更新。

## GitHub Actions 打包发布

工作流：[release.yml](.github/workflows/release.yml)。

在 **Ubuntu 26.04** 上直接生成供 OpenWrt 使用的 APK v3 包，无需下载 SDK、准备 feeds 或选择 CPU 架构。

1. 将项目提交到 GitHub，保持 `Makefile`、`htdocs`、`root` 和 `.github` 位于仓库根目录。
2. 进入 **Actions → Release → Run workflow**。
3. 选择构建分支，填写新标签，例如 `v1.2`。
4. 按需勾选 `prerelease`，然后运行工作流。

缓存未命中时下载并编译固定版本的 APK 打包工具，缓存命中时复用。发布时复制文件，使用 `apk mkpkg` 生成一个安装包并上传 Release。安装和升级脚本处理 LuCI 缓存刷新。

版本号取标签去掉 `v` 的部分，标签格式为 `v数字.数字`；包修订号和运行依赖取自 `Makefile`。

发布文件（`PKG_RELEASE:=3`）：

```text
luci-app-sing_<版本>_r3.apk
luci-app-sing-<版本>-3.ipk
```

安装包为 `noarch`，面板自身不含架构相关的二进制文件。sing-box 内核和其他运行依赖由设备的软件源提供，设备需要可用且匹配固件的软件源。`noarch` 不代表兼容所有系统；面板依赖 OpenWrt 的 UCI、ubus、procd 和 LuCI 运行环境。

发布使用仓库自带的 `GITHUB_TOKEN`。请填写尚未存在的标签；若发布中断后已有同名标签或 Release 草稿，处理残留后重试，或使用新版本号。

APK 直接上传到 Release，构建日志在 Actions 运行页面查看。工作流不运行测试、lint 或额外校验任务。

## 从源码构建

在 Linux 上使用与目标固件匹配的 OpenWrt SDK 或源码树，将项目放到 `package/luci-app-sing`：

```sh
./scripts/feeds update -a
./scripts/feeds install -a
make menuconfig
```

选择：

- **LuCI → Applications → luci-app-sing**

也可通过 `LUCI_SING_VERSION` 指定源码构建的版本号。保存配置后构建：

```sh
make package/luci-app-sing/compile V=s
```

生成的安装包位于 `bin/packages/` 下

## 故障排查

- **页面没有出现**：重启 `rpcd` 后重新登录 LuCI。
- **配置校验失败**：根据页面显示的 sing-box 错误修改 JSON，确认 `conffile`、`workdir` 及引用文件路径。
- **系统日志为空**：检查启动脚本的日志收集设置，以及 JSON 中的 `log.output` 和 `log.disabled`。
- **操作长时间未结束**：检查 `/tmp/sing-box-panel/lock/pid` 对应的后台进程。确认进程已退出后，再处理锁和临时任务数据。

临时任务数据位于 `/tmp/sing-box-panel/`，设备重启后会清除。

## 参考

- [sing-box 配置文档](https://sing-box.sagernet.org/configuration/)
- [sing-box 上游OpenWrt启动脚本](https://github.com/SagerNet/sing-box/blob/testing/release/config/openwrt.init)
- [LuCI 上游项目](https://github.com/lauyv/luci-app-sing-box)
- [LuCI 应用示例](https://github.com/openwrt/luci/tree/master/applications/luci-app-example)

## 许可证

[MIT](LICENSE)
