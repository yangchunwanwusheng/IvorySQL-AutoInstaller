
<p align="right">
  <a href="#english">English</a> | <a href="#中文">中文</a>
</p>

<a id="english"></a>
# IvorySQL-AutoInstall — User Guide (Aligned Bilingual, Architecture Section Removed)


## 1. Project Introduction

IvorySQL-AutoInstall is a professional automated installation script designed to simplify the process of compiling and installing the IvorySQL database. With a simple configuration file, users can complete the entire workflow—from building from source to starting the service—with one command, without manually executing complex build commands and configuration steps.

### 1.1 Core Features
- **Environment detection and validation**: Automatically detect the operating system type and version, and validate compatibility.
- **Intelligent dependency management**: Automatically install build-time dependencies, supporting multiple platform package managers.
- **Source retrieval and compilation**: Fetch source code from a specified repository and accelerate builds with parallel compilation.
- **Automated installation and configuration**: Automatically set permissions for the install directory, data directory, and log directory.
- **Service integration**: Automatically create a systemd service (or a helper when systemd is absent) and configure environment variables.
- **Comprehensive logging**: Record detailed installation steps to facilitate troubleshooting.
- **Error handling and rollback**: Robust error detection and handling mechanisms.
- **Interactive and non-interactive**: `NON_INTERACTIVE=1` auto-accepts specific confirmations (see §2.6).

### 1.2 Supported Operating Systems
| Family        | Distribution/ID                                     | Version Gate in Script                                  | Notes                        |
|---------------|------------------------------------------------------|---------------------------------------------------------|------------------------------|
| RHEL Family   | rhel / centos / almalinux / rocky / fedora / oracle | Explicitly **blocks 7**; code paths cover 8/9/10        | Oracle Linux has specifics   |
| Debian/Ubuntu | debian / ubuntu                                     | Version validated; unsupported versions **fail fast**   | Uses `apt` for dependencies  |
| SUSE Family   | opensuse-leap / sles                                 | openSUSE Leap **15**; SLES **12.5 / 15**                | Uses `zypper`                |
| Arch          | arch                                                 | Rolling release                                         | Uses `pacman`                |

> **Note**: CentOS 7 is **not** supported by this project.

---

## 2. Project Details

### 2.1 Configuration File Explained (`ivorysql.conf`)
| Key           | Required | Default | Description                                                  |
|---------------|----------|---------|--------------------------------------------------------------|
| INSTALL_DIR   | Yes      | None    | Install directory for IvorySQL (absolute path required)      |
| DATA_DIR      | Yes      | None    | Database data directory (absolute path required)             |
| LOG_DIR       | Yes      | None    | Log directory (absolute path required)                       |
| SERVICE_USER  | Yes      | None    | Service user (must not be a reserved system account)         |
| SERVICE_GROUP | Yes      | None    | Service group (must not be a reserved system group)          |
| REPO_URL      | Yes      | None    | IvorySQL source repository URL                                |
| TAG           | Optional | None    | Specific release tag to install (**preferred when present**) |
| BRANCH        | Optional | None    | Source branch to install                                     |

**Notes**
- Paths must be absolute and contain no spaces.
- Provide either **TAG** or **BRANCH**; when both are set, **TAG takes precedence**.
- User/group names must not be reserved names (e.g., `root`, `bin`, `daemon`).

**Example**
```ini
INSTALL_DIR=/usr/ivorysql
DATA_DIR=/var/lib/ivorysql/data
LOG_DIR=/var/log/ivorysql
SERVICE_USER=ivorysql
SERVICE_GROUP=ivorysql
REPO_URL=https://github.com/IvorySQL/IvorySQL.git
TAG=IvorySQL_4.5.3
```

### 2.2 Dependency Management System

#### Core Dependencies (mandatory, installed automatically)
- Toolchain: GCC, Make, Flex, Bison
- Core libraries: readline, zlib, openssl
- Perl environment: perl-core, perl-devel, perl-IPC-Run

#### Optional Dependencies (smart detection; feature disabled if missing)
| Library  | Probe Path(s)                                           | Automatic Handling                               |
|----------|----------------------------------------------------------|--------------------------------------------------|
| ICU      | `/usr/include/icu.h` or `/usr/include/unicode/utypes.h` | Add `--without-icu` if not detected              |
| libxml2  | `/usr/include/libxml2/libxml/parser.h`                  | Add `--without-libxml` if not detected           |
| Tcl      | `/usr/include/tcl.h`                                    | Add `--without-tcl` if not detected              |
| Perl dev | headers present                                          | Add `--without-perl` if not detected             |

#### OS-Specific Install Commands
| OS                          | Commands                                                                 |
|-----------------------------|--------------------------------------------------------------------------|
| RHEL Family (CentOS/RHEL/Rocky) | `dnf group install "Development Tools"` <br> `dnf install readline-devel zlib-devel openssl-devel` |
| Debian/Ubuntu               | `apt-get install build-essential libreadline-dev zlib1g-dev libssl-dev` |
| SUSE/SLES                   | `zypper install gcc make flex bison readline-devel zlib-devel libopenssl-devel` |
| Arch Linux                  | `pacman -S base-devel readline zlib openssl`                             |

**Toolchain verification**
```bash
for cmd in gcc make flex bison; do
  command -v "$cmd" >/dev/null || echo "Warning: $cmd is not installed"
done
```

### 2.3 Build Process

#### Versioning
- Prefer **TAG**. If TAG is not provided, use **BRANCH**.
- Record the short **COMMIT_ID** for the success report.

#### Configure
```bash
./configure --prefix="$INSTALL_DIR" --with-openssl --with-readline             --without-icu \        # when ICU is not detected
            --without-libxml \     # when libxml2 is not detected
            --without-tcl \        # when Tcl is not detected
            --without-perl         # when Perl dev env is not detected
```

#### Parallel Compilation
```bash
make -j"$(nproc)"
make install
```

#### Post-Install
- Ensure `$DATA_DIR` exists, `chmod 700`, and correct ownership.
- Optionally append `$INSTALL_DIR/bin` to the service user's PATH.

### 2.4 Service Management System

#### **systemd Path** 
unit generated by the script
```ini
[Unit]
Description=IvorySQL Database Server
Documentation=https://www.ivorysql.org
Requires=network.target local-fs.target
After=network.target local-fs.target

[Service]
Type=forking
User=ivorysql
Group=ivorysql
Environment=PGDATA=/var/lib/ivorysql/data
Environment=LD_LIBRARY_PATH=/usr/ivorysql/lib:/usr/ivorysql/lib/postgresql
PIDFile=/var/lib/ivorysql/data/postmaster.pid
OOMScoreAdjust=-1000
ExecStart=/usr/ivorysql/bin/pg_ctl start -D ${PGDATA} -s -w -t 90
ExecStop=/usr/ivorysql/bin/pg_ctl stop -D ${PGDATA} -s -m fast
ExecReload=/usr/ivorysql/bin/pg_ctl reload -D ${PGDATA}
TimeoutSec=120
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

**Notes**
- `PIDFile` is present in the generated unit.
- `ExecStart` uses `-t 90` and `TimeoutSec` is **120** to match the script.
- `OOMScoreAdjust=-1000` and `Type=forking` are configured.

#### **Non-systemd Path**
- Helper script: `"$INSTALL_DIR/ivorysql-ctl"` (created by the script)
  - `start` → `pg_ctl start -D "$DATA_DIR" -s -w -t 90`
  - `stop`  → `pg_ctl stop  -D "$DATA_DIR" -s -m fast`
  - `reload`→ `pg_ctl reload -D "$DATA_DIR"`
- **Note**: The script also has an internal fallback `svc_start` path that uses `-t 60` when not leveraging the helper; the helper defaults to **90 seconds**.

### 2.5 Logging System

```
/var/log/ivorysql/
├── install_YYYYmmdd_HHMMSS.log  # installer stdout
├── error_YYYYmmdd_HHMMSS.log    # installer stderr
├── initdb_YYYYmmdd_HHMMSS.log   # initdb logs
└── postgresql.log               # server runtime log
```

- Ownership: `ivorysql:ivorysql`
- Timestamped, step-tagged installer logs
- PostgreSQL built-in runtime logging

### 2.6 Non-Interactive Mode (`NON_INTERACTIVE`)
- Read at startup: `NON_INTERACTIVE="${NON_INTERACTIVE:-0}"`.
- When **`NON_INTERACTIVE=1`**, the installer **auto-accepts**:
  1) Using a **non-official** repository (when `REPO_URL` is not under `github.com/IvorySQL/IvorySQL`)
  2) Overlong `TAG` / `BRANCH` identifiers (length > 100)
- This mode does **not** skip validations or errors—only confirmations.

---

## 3. User Guide

### 3.1 Preparation
1. Switch to root:
   ```bash
   su -
   # or
   sudo -i
   ```
2. Clone the project:
   ```bash
   git clone https://github.com/yangchunwanwusheng/IvorySQL-AutoInstaller.git
   ```
3. Enter the directory and add execute permission:
   ```bash
   cd IvorySQL-AutoInstaller
  
   ```
    ```bash
   
   chmod +x AutoInstall.sh
   ```

### 3.2 Configuration Changes (optional)
1. Edit the configuration file:
   ```bash
   nano ivorysql.conf
   ```
2. Reference (absolute paths only; `LOG_DIR` is required):
   ```ini
   INSTALL_DIR=/usr/ivorysql
   DATA_DIR=/var/lib/ivorysql/data
   SERVICE_USER=ivorysql
   SERVICE_GROUP=ivorysql
   REPO_URL=https://github.com/IvorySQL/IvorySQL.git
   LOG_DIR=/var/log/ivorysql
   TAG=IvorySQL_4.5.3
   # BRANCH=
   ```

### 3.3 Interactive Installation (default)
```bash
sudo bash AutoInstall.sh -c ivorysql.conf
```

### 3.4 Non-Interactive Installation (CI/unattended)
```bash
NON_INTERACTIVE=1 sudo bash AutoInstall.sh -c ivorysql.conf
```

### 3.5 Installation Verification (exact format from the script)
```
================ Installation succeeded ================

Install directory: /usr/ivorysql
Data directory: /var/lib/ivorysql/data
Log directory: /var/log/ivorysql
Service: active
Version: /usr/ivorysql/bin/postgres --version output

Useful commands:
  systemctl [start|stop|status] ivorysql
  journalctl -u ivorysql -f
  sudo -u ivorysql '/usr/ivorysql/bin/psql'

Install time: <date>
Elapsed: <seconds>s
Build: <TAG or BRANCH>   Commit: <short commit or N/A>
OS: <os_type> <os_version>
```

### 3.6 Service Management Commands
| Action | Command | Notes |
|---|---|---|
| Start | `systemctl start ivorysql` | Start the database service |
| Stop  | `systemctl stop ivorysql`  | Stop the database service  |
| Status| `systemctl status ivorysql`| Inspect service state      |
| Logs  | `journalctl -u ivorysql -f`| Follow service logs        |
| Reload| `systemctl reload ivorysql`| Reload configurations      |
| Connect | `sudo -u ivorysql /usr/ivorysql/bin/psql` | Connect to DB |
| Version | `/usr/ivorysql/bin/postgres --version` | Show version |
| Base Backup | `sudo -u ivorysql /usr/ivorysql/bin/pg_basebackup` | Create base backup |

---

## 4. Troubleshooting

### 4.1 Common Error Handling
| Symptom | Likely Cause | Resolution |
|---|---|---|
| Configuration missing | Wrong file path | Ensure `ivorysql.conf` exists in the project directory |
| Dependency install failed | Network or mirror issues | Check network; switch mirrors |
| Build error | Unsupported environment | Check OS/version; inspect error log |
| initdb failed | Ownership or permissions | `chown ivorysql:ivorysql /var/lib/ivorysql/data` |
| Service failed | Port conflict or configuration | `ss -tulnp | grep 5432` |

### 4.2 Diagnostic Commands
```bash
systemctl status ivorysql -l --no-pager
journalctl -u ivorysql --since "1 hour ago" --no-pager
sudo -u ivorysql /usr/ivorysql/bin/postgres -D /var/lib/ivorysql/data -c logging_collector=on
ls -l IvorySQL-AutoInstaller/ivorysql.conf
cat IvorySQL-AutoInstaller/ivorysql.conf
```

### 4.3 Log File Locations
- Install logs: `/var/log/ivorysql/install_<timestamp>.log`
- Error logs: `/var/log/ivorysql/error_<timestamp>.log`
- initdb logs: `/var/log/ivorysql/initdb_<timestamp>.log`
- DB logs: `/var/log/ivorysql/postgresql.log`

### 4.4 Special Handling
#### Rocky Linux 10 / Oracle Linux 10
- Auto-enable CRB/Devel repositories for dev headers (e.g., `libxml2-devel`).
- Fallback `--allowerasing` strategy when appropriate.
- Check status:
  ```bash
  grep "XML_SUPPORT" /var/log/ivorysql/install_*.log
  ```

#### Perl Environment
- Auto-check `FindBin`, `IPC::Run`. Install via package manager or CPAN if missing.
```bash
dnf install -y perl-IPC-Run
PERL_MM_USE_DEFAULT=1 cpan -i IPC::Run FindBin
perl -MFindBin -e 1
perl -MIPC::Run -e 1
```

---

<a id="中文"></a>
# IvorySQL-AutoInstall — 使用文档（双语对齐，移除“项目架构”）

## 1. 项目介绍

IvorySQL-AutoInstall 是一个专业的自动化安装脚本，旨在简化 IvorySQL 数据库的编译安装过程。通过简单的配置文件设置，用户可以一键完成从源码编译到服务启动的全过程，无需手动执行复杂的编译命令和配置步骤。

### 1.1 核心功能
- **环境检测与验证**：自动检测操作系统类型和版本，验证系统兼容性。
- **智能依赖管理**：自动安装编译所需依赖包，支持多平台包管理器。
- **源码获取与编译**：从指定仓库获取源代码，并行编译以提升速度。
- **自动化安装配置**：自动设置安装目录、数据目录和日志目录的权限。
- **服务集成**：自动创建 systemd 服务（或在无 systemd 时创建辅助脚本）并配置环境变量。
- **全面日志记录**：详细记录安装过程，便于故障排查。
- **错误处理与回滚**：完善的错误检测与处理机制。
- **交互/非交互**：`NON_INTERACTIVE=1` 自动接受特定确认（见 §2.6）。

### 1.2 支持的操作系统
| 家族 | 发行版/ID | 脚本中的版本门槛 | 说明 |
|---|---|---|---|
| RHEL 系 | rhel / centos / almalinux / rocky / fedora / oracle | 明确 **屏蔽 7**；涵盖 8/9/10 的分支 | Oracle Linux 有专项处理 |
| Debian/Ubuntu | debian / ubuntu | 版本会被校验；不支持的版本 **快速失败** | 依赖安装使用 `apt` |
| SUSE 系 | opensuse-leap / sles | openSUSE Leap **15**；SLES **12.5 / 15** | 使用 `zypper` |
| Arch | arch | 滚动发布 | 使用 `pacman` |

> **注意**：本项目不支持 CentOS 7。

---

## 2. 项目细节

### 2.1 配置文件详解（`ivorysql.conf`）
| 配置项 | 是否必需 | 默认值 | 说明 |
|---|---|---|---|
| INSTALL_DIR | 是 | 无 | IvorySQL 安装目录（必须为绝对路径） |
| DATA_DIR | 是 | 无 | 数据目录（必须为绝对路径） |
| LOG_DIR | 是 | 无 | 日志目录（必须为绝对路径） |
| SERVICE_USER | 是 | 无 | 服务用户（不可为保留系统账户） |
| SERVICE_GROUP | 是 | 无 | 服务用户组（不可为保留系统组） |
| REPO_URL | 是 | 无 | IvorySQL 源码仓库 URL |
| TAG | 可选 | 无 | 指定版本标签（存在时**优先使用**） |
| BRANCH | 可选 | 无 | 指定源码分支 |

**注意**
- 所有路径必须为绝对路径，且不得包含空格。
- 必须设置 **TAG** 或 **BRANCH** 之一；同时设置时以 **TAG 优先**。
- 用户/组名称不得为系统保留名称（如 `root`、`bin`、`daemon`）。

**示例**
```ini
INSTALL_DIR=/usr/ivorysql
DATA_DIR=/var/lib/ivorysql/data
LOG_DIR=/var/log/ivorysql
SERVICE_USER=ivorysql
SERVICE_GROUP=ivorysql
REPO_URL=https://github.com/IvorySQL/IvorySQL.git
TAG=IvorySQL_4.5.3
```

### 2.2 依赖管理系统

#### 核心依赖（必装，自动执行）
- 工具链：GCC、Make、Flex、Bison
- 核心库：readline、zlib、openssl
- Perl 环境：perl-core、perl-devel、perl-IPC-Run

#### 可选依赖（智能检测，缺失则禁用对应特性）
| 依赖库 | 检测路径 | 自动处理 |
|---|---|---|
| ICU | `/usr/include/icu.h` 或 `/usr/include/unicode/utypes.h` | 未检测到则添加 `--without-icu` |
| libxml2 | `/usr/include/libxml2/libxml/parser.h` | 未检测到则添加 `--without-libxml` |
| Tcl | `/usr/include/tcl.h` | 未检测到则添加 `--without-tcl` |
| Perl 开发 | 头文件存在 | 未检测到则添加 `--without-perl` |

#### 各发行版安装命令
| 系统 | 命令 |
|---|---|
| RHEL 系（CentOS/RHEL/Rocky） | `dnf group install "Development Tools"` <br> `dnf install readline-devel zlib-devel openssl-devel` |
| Debian/Ubuntu | `apt-get install build-essential libreadline-dev zlib1g-dev libssl-dev` |
| SUSE/SLES | `zypper install gcc make flex bison readline-devel zlib-devel libopenssl-devel` |
| Arch Linux | `pacman -S base-devel readline zlib openssl` |

**工具链自检**
```bash
for cmd in gcc make flex bison; do
  command -v "$cmd" >/dev/null || echo "警告: 未安装 $cmd"
done
```

### 2.3 编译流程

#### 版本策略
- **优先**使用 **TAG**；未提供时使用 **BRANCH**。
- 在成功报告中记录短 **COMMIT_ID**。

#### 配置命令
```bash
./configure --prefix="$INSTALL_DIR" --with-openssl --with-readline             --without-icu \        # 未检测到 ICU 时
            --without-libxml \     # 未检测到 libxml2 时
            --without-tcl \        # 未检测到 Tcl 时
            --without-perl         # 未检测到 Perl 开发环境时
```

#### 并行编译
```bash
make -j"$(nproc)"
make install
```

#### 安装后处理
- 确保 `$DATA_DIR` 存在，设置 `chmod 700`，并修正属主。
- 可在服务用户的 PATH 中加入 `$INSTALL_DIR/bin`。

### 2.4 服务管理系统

#### **systemd 路径**
脚本生成的单元
```ini
[Unit]
Description=IvorySQL Database Server
Documentation=https://www.ivorysql.org
Requires=network.target local-fs.target
After=network.target local-fs.target

[Service]
Type=forking
User=ivorysql
Group=ivorysql
Environment=PGDATA=/var/lib/ivorysql/data
Environment=LD_LIBRARY_PATH=/usr/ivorysql/lib:/usr/ivorysql/lib/postgresql
PIDFile=/var/lib/ivorysql/data/postmaster.pid
OOMScoreAdjust=-1000
ExecStart=/usr/ivorysql/bin/pg_ctl start -D ${PGDATA} -s -w -t 90
ExecStop=/usr/ivorysql/bin/pg_ctl stop -D ${PGDATA} -s -m fast
ExecReload=/usr/ivorysql/bin/pg_ctl reload -D ${PGDATA}
TimeoutSec=120
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

**说明**
- 生成的单元包含 `PIDFile`。
- `ExecStart` 使用 `-t 90`，`TimeoutSec` 为 **120**，与脚本一致。
- 配置了 `OOMScoreAdjust=-1000` 与 `Type=forking`。

#### **非 systemd 路径**
- 辅助脚本：`"$INSTALL_DIR/ivorysql-ctl"`（由脚本生成）
  - `start` → `pg_ctl start -D "$DATA_DIR" -s -w -t 90`
  - `stop`  → `pg_ctl stop  -D "$DATA_DIR" -s -m fast`
  - `reload`→ `pg_ctl reload -D "$DATA_DIR"`
- **提示**：脚本还存在内部回退的 `svc_start` 路径，在不使用辅助脚本时采用 `-t 60`；辅助脚本默认 **90 秒**。

### 2.5 日志系统
```
/var/log/ivorysql/
├── install_YYYYmmdd_HHMMSS.log  # 安装器标准输出
├── error_YYYYmmdd_HHMMSS.log    # 安装器标准错误
├── initdb_YYYYmmdd_HHMMSS.log   # 初始化日志
└── postgresql.log               # 运行期日志
```

- 目录属主：`ivorysql:ivorysql`
- 安装日志带时间戳与步骤标记
- 运行期使用 PostgreSQL 内置日志

### 2.6 非交互模式（`NON_INTERACTIVE`）
- 启动时读取：`NON_INTERACTIVE="${NON_INTERACTIVE:-0}"`。
- 当 **`NON_INTERACTIVE=1`** 时，安装器**自动接受**：
  1) 使用**非官方仓库**（当 `REPO_URL` 不在 `github.com/IvorySQL/IvorySQL`）
  2) 过长的 `TAG` / `BRANCH` 标识（长度 > 100）
- 该模式**不**跳过校验或错误，仅用于跳过确认交互。

---

## 3. 使用指南

### 3.1 准备工作
1. **使用 root 权限**：
   ```bash
   su -
   # 或
   sudo -i
   ```
2. **克隆项目**：
   ```bash
   git clone https://github.com/yangchunwanwusheng/IvorySQL-AutoInstaller.git
   ```
3. **进入目录并添加执行权限**：
   ```bash
   cd IvorySQL-AutoInstaller
  
   ```
    ```bash
  
   chmod +x AutoInstall.sh
   ```
### 3.2 配置修改（可选）
1. **编辑配置文件**：
   ```bash
   nano ivorysql.conf
   ```
2. **配置参考**（路径须为绝对路径；`LOG_DIR` 必填）：
   ```ini
   INSTALL_DIR=/usr/ivorysql
   DATA_DIR=/var/lib/ivorysql/data
   SERVICE_USER=ivorysql
   SERVICE_GROUP=ivorysql
   REPO_URL=https://github.com/IvorySQL/IvorySQL.git
   LOG_DIR=/var/log/ivorysql
   TAG=IvorySQL_4.5.3
   # BRANCH=
   ```

### 3.3 交互式安装（默认）
```bash
sudo bash AutoInstall.sh -c ivorysql.conf
```

### 3.4 非交互式安装（CI/无人值守）
```bash
NON_INTERACTIVE=1 sudo bash AutoInstall.sh -c ivorysql.conf
```

### 3.5 安装验证（脚本实际输出格式）
```
================ Installation succeeded ================

Install directory: /usr/ivorysql
Data directory: /var/lib/ivorysql/data
Log directory: /var/log/ivorysql
Service: active
Version: /usr/ivorysql/bin/postgres --version output

Useful commands:
  systemctl [start|stop|status] ivorysql
  journalctl -u ivorysql -f
  sudo -u ivorysql '/usr/ivorysql/bin/psql'

Install time: <date>
Elapsed: <seconds>s
Build: <TAG or BRANCH>   Commit: <short commit or N/A>
OS: <os_type> <os_version>
```

### 3.6 服务管理命令
| 功能 | 命令 | 说明 |
|---|---|---|
| 启动 | `systemctl start ivorysql` | 启动数据库服务 |
| 停止 | `systemctl stop ivorysql`  | 停止数据库服务 |
| 状态 | `systemctl status ivorysql`| 查看服务状态   |
| 日志 | `journalctl -u ivorysql -f`| 跟踪服务日志   |
| 重载 | `systemctl reload ivorysql`| 重载配置       |
| 连接 | `sudo -u ivorysql /usr/ivorysql/bin/psql` | 连接数据库 |
| 版本 | `/usr/ivorysql/bin/postgres --version` | 查看版本 |
| 基础备份 | `sudo -u ivorysql /usr/ivorysql/bin/pg_basebackup` | 创建基础备份 |

---

## 4. 故障排查

### 4.1 常见错误处理
| 错误现象 | 可能原因 | 解决方案 |
|---|---|---|
| 配置文件缺失 | 路径错误 | 检查项目目录下是否存在 `ivorysql.conf` |
| 依赖安装失败 | 网络或镜像问题 | 检查网络并尝试切换镜像 |
| 构建错误 | 环境不受支持 | 检查系统版本并查看错误日志 |
| initdb 失败 | 属主或权限问题 | `chown ivorysql:ivorysql /var/lib/ivorysql/data` |
| 服务失败 | 端口冲突或配置错误 | `ss -tulnp | grep 5432` |

### 4.2 诊断命令
```bash
systemctl status ivorysql -l --no-pager
journalctl -u ivorysql --since "1 hour ago" --no-pager
sudo -u ivorysql /usr/ivorysql/bin/postgres -D /var/lib/ivorysql/data -c logging_collector=on
ls -l IvorySQL-AutoInstaller/ivorysql.conf
cat IvorySQL-AutoInstaller/ivorysql.conf
```

### 4.3 日志位置
- 安装日志：`/var/log/ivorysql/install_<timestamp>.log`
- 错误日志：`/var/log/ivorysql/error_<timestamp>.log`
- 初始化日志：`/var/log/ivorysql/initdb_<timestamp>.log`
- 数据库日志：`/var/log/ivorysql/postgresql.log`

### 4.4 特殊处理
#### Rocky Linux 10 / Oracle Linux 10
- 自动启用 CRB/Devel 仓库以获取开发头文件（如 `libxml2-devel`）。
- 需要时采用 `--allowerasing` 的回退策略。
- 状态检查：
  ```bash
  grep "XML_SUPPORT" /var/log/ivorysql/install_*.log
  ```

#### Perl 环境
- 自动检查 `FindBin`、`IPC::Run`；缺失时通过包管理器或 CPAN 安装。
```bash
dnf install -y perl-IPC-Run
PERL_MM_USE_DEFAULT=1 cpan -i IPC::Run FindBin
perl -MFindBin -e 1
perl -MIPC::Run -e 1
```






