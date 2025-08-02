
# IvorySQL 自动化安装脚本使用文档

## 脚本概述

`IvorySQL-AutoInstaller` 是一个自动化源码编译安装 IvorySQL 数据库的 Bash 脚本，支持主流 Linux 发行版。该脚本实现了从源码获取、编译安装到系统服务集成的全流程自动化，特别适合在需要特定编译参数或定制版本的场景下使用。

## 核心功能说明

### 1. 配置管理
- **配置文件路径**：`/etc/ivorysql/install.conf`
- **关键配置项**：
  ```ini
  INSTALL_DIR      = "/opt/ivorysql"       # 安装目录（必需）
  DATA_DIR         = "/data/ivorysql"      # 数据目录（必需）
  SERVICE_USER     = "ivoryuser"           # 服务运行用户（必需）
  SERVICE_GROUP    = "ivorygroup"          # 服务运行组（必需）
  REPO_URL         = "https://github.com/xxx/IvorySQL.git"  # 源码仓库（必需）
  TAG              = "v2.1.0"              # 优先使用的版本标签（与分支二选一）
  BRANCH           = "main"                # 源码分支
  LOG_DIR          = "/var/log/ivorysql"   # 日志目录（默认值）
  ```

### 2. 依赖管理
支持的 Linux 发行版：
- RHEL/CentOS/Rocky/AlmaLinux (8/9)
- Ubuntu/Debian (18.04-24.04)
- openSUSE/SLES (15+)

**自动安装的依赖**：
- 编译工具链：GCC, Make, Flex, Bison
- 核心库：readline, zlib, openssl
- 可选库支持：
  - ICU (检测路径：`/usr/include/icu.h`)
  - libxml2 (检测路径：`/usr/include/libxml2/libxml/parser.h`)
  - TCL (检测路径：`/usr/include/tcl.h`)

> **注意**：CentOS/RHEL 7 需手动通过官方源安装，不支持本脚本

### 3. 源码编译
**编译流程和配置**：
1. 版本控制优先顺序：`TAG` > `BRANCH`
2. 强制启用 OpenSSL：`--with-openssl`
3. 智能依赖检测：
   ```bash
   --without-icu             # 当检测不到 /usr/include/icu.h 时禁用
   --without-libxml           # 当检测不到 /usr/include/libxml2/libxml/parser.h 时禁用
   --without-tcl              # 当检测不到 /usr/include/tcl.h 时禁用
   ```
4. 并行编译优化：使用 `make -j$(nproc)` 基于 CPU 核心数并行编译
5. 版本标识保留：记录安装版本的 Git Commit ID

### 4. 服务集成
**生成的 systemd 服务文件**：
- 路径：`/etc/systemd/system/ivorysql.service`
- 关键配置：
  ```ini
  [Service]
  Type=forking
  User=${SERVICE_USER}
  Group=${SERVICE_GROUP}
  Environment=PGDATA=${DATA_DIR}
  ExecStart=${INSTALL_DIR}/bin/pg_ctl start -D ${PGDATA} -s -w -t 60
  ExecStop=${INSTALL_DIR}/bin/pg_ctl stop -D ${PGDATA} -s -m fast
  ExecReload=${INSTALL_DIR}/bin/pg_ctl reload -D ${PGDATA}
  TimeoutSec=0                # 永不超时
  Restart=on-failure          # 故障时自动重启
  RestartSec=5s               # 重启间隔
  OOMScoreAdjust=-1000        # 防止OOM Killer终止数据库进程
  ```

**环境变量配置**：
- 添加至用户 `~/.bash_profile`：
  ```bash
  # --- IvorySQL Environment Configuration ---
  PATH="${INSTALL_DIR}/bin:$PATH"
  export PATH
  PGDATA="${DATA_DIR}"
  export PGDATA
  # --- End of Configuration ---
  ```

### 5. 日志系统
**日志文件结构**：
```
${LOG_DIR}/
├── install_20250101_120000.log   # 安装过程日志
├── error_20250101_120000.log     # 错误日志
└── postgresql.log                # 数据库运行日志（服务启动后生成）
```

**权限设置**：
```bash
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${LOG_DIR}"
```

## 使用流程

### 准备步骤
1. 创建配置文件：
   ```bash
   sudo mkdir -p /etc/ivorysql
   sudo vim /etc/ivorysql/install.conf
   ```
2. 填写必要配置（至少包含 INSTALL_DIR, DATA_DIR, SERVICE_USER, SERVICE_GROUP, REPO_URL）
3. 保存后脚本会自动设置安全权限：
   ```bash
   chmod 600 /etc/ivorysql/install.conf
   ```

### 执行安装
```bash
chmod +x AutoInstall.sh
sudo ./AutoInstall.sh
```

### 安装验证
成功后的关键输出：
```text
================ 安装成功 ================
安装目录: /opt/ivorysql
数据目录: /data/ivorysql
日志目录: /var/log/ivorysql
服务状态: active
数据库版本: ivorysql (IvorySQL) 2.1.0
...

安装耗时: 215 秒
```

### 管理命令
| 功能 | 命令 |
|------|------|
| 启动服务 | `systemctl start ivorysql` |
| 停止服务 | `systemctl stop ivorysql` |
| 查看状态 | `systemctl status ivorysql` |
| 查看日志 | `journalctl -u ivorysql -f` |
| 服务重载 | `systemctl reload ivorysql` |
| 数据库连接 | `sudo -u ivoryuser /opt/ivorysql/bin/psql` |

