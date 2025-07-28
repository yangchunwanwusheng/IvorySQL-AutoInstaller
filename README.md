# IvorySQL 自动化安装脚本使用文档

## 1. 脚本概述

这是专门为源码编译安装 **IvorySQL 数据库**设计的自动化脚本，适用于多种主流Linux发行版。脚本已托管在 GitHub 仓库：[yangchunwanwusheng/AutoInstall.sh](https://github.com/yangchunwanwusheng/AutoInstall.sh)

### 核心实现功能：
- ✅ **环境检测**：检查操作系统类型和版本
- ✅ **源码获取**：从 GitHub 获取指定分支的源代码
- ✅ **编译安装**：自动进行源码编译和二进制安装
- ✅ **数据库初始化**：自动执行数据库初始化操作
- ✅ **服务管理**：创建并启动数据库服务
- ✅ **错误处理**：提供详细的错误信息和解决方案

## 2. 安装前准备

### 2.1 系统要求
- **操作系统**：
  - CentOS/RHEL 8+
  - Ubuntu 18.04+
  - Debian 10+
  - openSUSE 15+
  - AlmaLinux/Rocky Linux 8+
- **硬件要求**：
  - 内存：≥1GB
  - 磁盘空间：≥5GB
- **环境要求**：
  - Internet 连接（用于下载源码和依赖）
  - root 权限

### 2.2 获取脚本
```bash
# 下载安装脚本
git clone https://github.com/yangchunwanwusheng/AutoInstall.sh.git
cd AutoInstall.sh

# 添加执行权限
chmod +x install_ivorysql.sh
```

## 3. 配置文件说明
首次运行时会自动生成配置文件：`/etc/ivorysql/install.conf`

### 默认配置：
```ini
INSTALL_DIR="/usr/local/ivorysql/ivorysql-4"
DATA_DIR="/var/lib/ivorysql/data"
SERVICE_USER="ivorysql"
SERVICE_GROUP="ivorysql"
REPO_URL="https://github.com/IvorySQL/IvorySQL.git"
BRANCH="IVORY_REL_4_STABLE"
LOG_DIR="/var/log/ivorysql"
```

### 配置技巧：
1. 首次运行脚本创建配置文件：
```bash
sudo ./install_ivorysql.sh
```
2. 当看到提示 **"发现现有配置文件"** 时，**立即按 Ctrl+C** 停止脚本
3. 编辑配置文件进行自定义：
```bash
sudo nano /etc/ivorysql/install.conf
```
4. 再次运行安装脚本

## 4. 安装流程

### 基本安装命令：
```bash
sudo ./install_ivorysql.sh
```

### 详细安装流程：
1. **环境检测**
   - 识别操作系统和版本
   - 验证 root 权限
   - 创建日志目录：`/var/log/ivorysql`

2. **源码获取**
   - 从 GitHub 克隆指定分支的源码
   - 使用分支：`IVORY_REL_4_STABLE`（默认）
   - 源码目录：`IvorySQL`

3. **编译安装**
   - 自动安装编译器（gcc, make）和依赖库
   - 并行编译（使用所有 CPU 核心）
   - 安装到指定目录：`/usr/local/ivorysql/ivorysql-4`

4. **数据库初始化**
   - 创建数据目录：`/var/lib/ivorysql/data`
   - 初始化数据库集群
   - 设置服务用户：`ivorysql`

5. **服务启动**
   - 创建 systemd 服务文件
   - 启动数据库服务
   - 验证服务状态

## 5. 安装后操作

### 服务管理：
```bash
# 启动服务
sudo systemctl start ivorysql

# 停止服务
sudo systemctl stop ivorysql

# 查看状态
sudo systemctl status ivorysql

# 设置开机启动
sudo systemctl enable ivorysql
```

### 日志查看：
```bash
# 安装日志
sudo less /var/log/ivorysql/install_*.log

# 数据库日志
sudo ls /var/log/ivorysql/
```

## 6. 自定义安装

### 修改配置文件选项：
```ini
# 自定义安装路径
INSTALL_DIR="/opt/ivorysql/4.3"

# 自定义数据目录
DATA_DIR="/bigdata/ivorysql"

# 安装开发版本
BRANCH="main"

# 自定义服务用户
SERVICE_USER="ivoryadmin"
```

## 7. 故障排除

### 常见错误处理：

| 错误 | 解决方案 |
|------|----------|
| **配置加载失败** | 检查 `/etc/ivorysql/install.conf` 权限 |
| **依赖安装失败** | 运行 `sudo apt update` 或 `sudo dnf update` |
| **源码编译失败** | 查看详细日志：`/var/log/ivorysql/error_*.log` |
| **服务启动失败** | 手动测试：`sudo -u ivorysql $INSTALL_DIR/bin/postgres -D $DATA_DIR` |

### 服务调试：
```bash
# 查看完整错误日志
sudo journalctl -u ivorysql -xe --no-pager

# 手动初始化测试
sudo -u ivorysql $INSTALL_DIR/bin/initdb -D $DATA_DIR --debug
```

## 8. 卸载指南

```bash
# 停止服务
sudo systemctl stop ivorysql
sudo systemctl disable ivorysql

# 删除安装目录（根据配置）
sudo rm -rf /usr/local/ivorysql/ivorysql-4

# 删除数据目录（警告：永久删除数据）
sudo rm -rf /var/lib/ivorysql/data

# 删除配置和日志
sudo rm -rf /etc/ivorysql /var/log/ivorysql

# 删除系统用户
sudo userdel ivorysql
sudo groupdel ivorysql
```

## 9. 注意事项
1. ⚠️ **生产环境**：首次安装请在测试环境验证
2. ⚠️ **磁盘空间**：确保 `/usr` 和 `/var` 有足够空间
3. ⚠️ **配置文件**：安装前务必按需修改配置
4. 💡 **优化建议**：
   - 数据目录建议放在独立分区
   - 对于生产环境，调整 `/etc/ivorysql/install.conf` 中的编译选项
5. 🛠️ **开发调试**：
   ```bash
   # 保留编译源码
   cd AutoInstall.sh/IvorySQL
   make clean && make -j$(nproc) && sudo make install
   ```

> **提示**：安装完成后请查看安装摘要，其中包含重要的路径和服务管理命令
