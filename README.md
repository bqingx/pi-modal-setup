# Pi → Modal Heretic 9B（一键 VPS 安装）

只安装 **Pi CLI**，连接已部署的 Modal API，并设为新会话默认模型。**没有 PiWeb、SSH/端口变更、sudo 或 shell profile 修改。** 公开仓库不包含任何服务 key、Modal/Kaggle/GitHub token 或内部运行日志。

## 安装

支持 Debian/Ubuntu Linux（glibc ≥ 2.28；自动 Node 安装支持 x86_64/aarch64）。以准备长期使用 Pi 的账号，在有交互终端的 VPS 登录会话执行。不要在当前正在运行 Pi 的账号下并发修改配置。

在 Bash 中执行这一行（固定到已测试的不可变 commit；先下载临时文件再运行）：

```bash
(umask 077; f=$(mktemp) && trap 'rm -f "$f"' EXIT && curl -fL --proto '=https' https://raw.githubusercontent.com/bqingx/pi-modal-setup/37dfe6c3c7220fb3ce3e10dfa2ca99560796ebfc/install.sh -o "$f" && bash "$f")
```

该 raw URL 已实际验证 HTTP 200 且与本地脚本逐字节相同。`install.sh` SHA256：`890ad7504e1b49f557e410bf5ede1453b1180ab2f7db29ab83e8d9350f1e27f7`。如需先审阅，下载后查看脚本再 `bash install.sh`。`bash install.sh --help` 不需要 TTY。脚本也支持 `curl | bash`。

系统需有 `bash python3 curl tar xz sha256sum`（常见 Debian/Ubuntu 镜像已包含；若缺少，会停止并提示用系统包管理器安装，不擅自提权）。例如缺少依赖时，由你决定执行 `sudo apt-get install python3 curl ca-certificates tar xz-utils coreutils` 后重试。

### 准备真正的 service API key

安装器只通过 **`/dev/tty` 隐藏输入**，不会要求把 key 写进命令。已有 `modal-heretic` 原生 API credential 可选择复用。回车取消空 key，Ctrl-C 可取消；确认前不修改配置。

服务拥有者的 OpenViking 凭据位置：

```text
privacy/credential/modal_model_api → values.api_key
{{ov_privacy:default:viking://~/privacy/credential/modal_model_api#/values/api_key}}
```

上面只是**引用，不是实际值**。通过已授权的 OpenViking privacy 凭据界面/解析工具安全取得实际 key，再粘贴到 VPS 的隐藏提示里；其他使用者需要向服务拥有者索取服务 key。**不能用 Modal 管理 token，也不能用引用、占位符或 GitHub/Kaggle token 代替。** 仓库和安装器不获取任何平台管理凭据。

## 安装行为与路径

- Pi 固定为 npm 官方包 `@earendil-works/pi-coding-agent@1.5.0`（Node 要求 `>=22.19.0`）。已在 PATH 且版本精确为 1.5.0 的 Pi 会复用；其他 Pi 不覆盖。
- 复用可用 Node ≥22.19 + npm；否则从 **nodejs.org** 下载 Node **22.22.0** 官方 Linux tar.xz，同时校验官方 SHASUMS256 和脚本内固定 SHA256（x64/arm64）。没有第三方 `curl | sudo bash`。不修改系统 Node/npm。
- 独立运行时/安装目录：`~/.local/share/pi-modal-setup/`，含 `node-v22.22.0-linux-<arch>/`、`pi-1.5.0/`、`npm-cache/`。npm 使用 `--ignore-scripts --no-audit --no-fund`；固定 Pi 顶层版本，不承诺锁定全部 npm 传递依赖。
- 自装 Pi 的 launcher：`~/.local/share/pi-modal-setup/pi`，仅固定 Node + CLI 路径，**不包含凭据或凭据环境变量**。若没有现有 `pi`，会在已存在、可写的绝对 PATH 目录中创建 `pi` symlink；不覆盖现有文件，不改 profile。如果 PATH 没有合适目录，使用安装器输出的绝对路径。若存在不同版本 Pi，仍用该绝对路径，不冒充已经切换系统 `pi`。
- agent-dir：`${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}`；设置自定义目录时，未来启动 Pi 也必须提供同一变量。工作目录 `.pi/settings.json`、已有 `enabledModels` scope、命令行参数、继续旧 session 可能覆盖启动选择；安装器只改全局 `defaultProvider` / `defaultModel`，不修改其它偏好。
- 合并 `models.json`，替换目标 `modal-heretic` provider 前要求确认，保留其它 provider。`settings.json` 仅更新两个默认字段。`auth.json` 中使用 **`"modal-heretic": {"type":"api_key","key":"<实际服务key>"}`**，保留其它 provider 的 API/OAuth credentials。
- **实际 key 只写入原生 `auth.json`（0600）及必要的 0600 旧配置备份**，不进入 models/settings、history、profiles、仓库或 launcher。用户已接受凭据落盘；0600 表示仅当前用户可读写，并非只读介质或加密。相同用户下的进程和 root 仍可读取。
- 修改过的三个配置文件均原子替换、0600。已有文件在修改前逐个备份至 agent-dir 下 `modal-setup-backup-<time>-<pid>/`（目录0700，文件0600，含 manifest）。无修改则不重复备份。无效/重复键 JSON、symlink、并发配置变化拒绝覆盖。使用安装锁及 Pi 的 `auth.json.lock` 目录约定；仍应先关闭其它 Pi 实例。
- 每文件原子写，不是跨三个文件的断电事务；普通写入失败会尝试回滚。断电/kill -9 或磁盘故障后需检查备份与配置。下载/安装失败不提交配置，可能留下已下载的独立运行时/cache；可安全重试。不要删除仍在使用的 lock。
- 不访问服务 API、不 warm GPU、不做推理健康检查。安装成功只表明配置已写入，不代表验证了服务 key 的正确性。

## 服务配置

- Base URL: `https://shelliminionhja33--heretic9b-persistent-api-gateway.us-east.modal.run/v1`
- Provider: `modal-heretic`; model: `qwen38-27b-aggr:q5kp`
- OpenAI Chat Completions / Bearer auth / 原生 tools / 文本输入；context **262144**（256K，实测可用），max output **16384**（Pi `maxTokens` 同步设为 16384，否则长文会在 4K 处被截断），模型 `qwen38-27b-aggr:q5kp`（Qwen3.8 27B HauhauCS Aggressive Q5_K_P，L40S 48GB）。
- 模型可能内部 reasoning，但未验证可调 thinking，因此 `reasoning:false`。具体兼容字段见 `pi-models.example.json`。URL 不要再附 `/chat/completions`。
- 首次 chat 会冷启动 GPU（可能数分钟）并收费。单请求并发，429 等前一请求结束再试；不要循环重试或自动保温。GPU idle 回收窗口约60秒仍计费，不承诺恰好60秒回收。服务拥有者需自行设 Modal 预算，安装器不设预算。
- 示例 cost 不标零，避免把实际 GPU 服务冒充免费；Pi 账面 token cost 不能代替 Modal 账单。

启动：在工作目录运行安装器输出的 `pi` 路径。新会话默认 `modal-heretic/qwen38-27b-aggr:q5kp`。Pi 可执行工具；**工作目录不是安全沙箱**，不要用拥有生产密钥/钱包的账号试用，建议独立账号或完整容器隔离。

## 卸载 / 恢复

先退出 Pi，确认没有其它进程修改配置。

1. 恢复：查看对应 backup 的 `manifest.json`。若此后没有其它配置变更，可将备份文件复制回同名位置并 `chmod 600`；`previouslyAbsent` 中的文件仅在确认没有后来添加的 provider/settings 后才可删除。**不要直接覆盖已有新改动**。有后续变更时，只从备份恢复 `providers.modal-heretic`、auth 的 `modal-heretic`，以及之前的两个 default 字段；其余 provider/settings 保留。备份本身含旧凭据，勿上传。
2. 只断开此服务而保留其它 Pi：编辑 JSON，删除 `models.json` 的 `providers.modal-heretic` 及 `auth.json` 的 `modal-heretic`；仅在 defaultProvider 仍为 modal-heretic 时删除/恢复两个默认字段。不要删除整个 `~/.pi` 或整个 auth.json。失效 key 应由服务拥有者在服务侧撤销/轮换，删除本地文件不等于撤销。
3. 若 Pi 由本脚本安装且无需保留，检查安装时输出的 PATH symlink，**只删除指向 `~/.local/share/pi-modal-setup/pi` 的那个 symlink**，再删除 `~/.local/share/pi-modal-setup/`。复用的 Pi/Node 不是本安装器所有，不应删除。配置和备份不自动删除。

## 验证与依据

```bash
bash -n install.sh
python3 -m unittest discover -s tests -v   # 离线 mock，dummy key，独立 HOME / PATH / agent-dir
python3 tests/live_install.py              # 可选：真实官方 Node + npm 下载，无模型/API调用
```

已实际通过：9项离线测试（新装、重复、保留其它 API/OAuth/provider/settings、备份及0600、无效JSON、取消/空key、非TTY、stdin pipe TTY、Node checksum失败、mock npm忽略scripts、symlink及重复键拒绝），以及真实 x64 Node 22.22.0 校验/安装、真实 npm Pi 1.5.0 安装、离线 `pi --list-models`、原生 auth 解析和默认模型选择。没有触发模型/GPU调用。arm64 checksum来自同版本官方清单，未在arm64机器运行。shellcheck 未预装，不宣称通过该检查。

核对的 Pi 官方发行包文档（1.5.0）：完整 README、docs/models.md、models-configuration.md、configuration.md、security.md、settings.md、providers.md，及相关 environment-variables.md、cli.md、containerization.md。文档入口：[Pi](https://github.com/earendil-works/pi)。

源码核对：`dist/core/auth-storage.js` 原生 api_key/key；`provider-composer.js` 的 `composeApiKeyAuth()` 对自定义 provider 会优先读取 stored credential，**即使 models.json 没有 apiKey / env**；`settings-manager.js` 的 defaultProvider/defaultModel；`model-resolver.js` 的 `findInitialModel()` 读取保存的默认并检查 auth。真实安装测试也离线验证了该逻辑。未实现 SDK 集成。
