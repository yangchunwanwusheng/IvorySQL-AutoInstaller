#!/bin/bash
set -eo pipefail

# -------------------------- 全局配置 --------------------------
CONFIG_FILE="/etc/ivorysql/install.conf"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

DEFAULT_CONFIG=$(cat <<EOF
INSTALL_DIR="/usr/local/ivorysql/ivorysql-4"
DATA_DIR="/var/lib/ivorysql/data"
SERVICE_USER="ivorysql"
SERVICE_GROUP="ivorysql"
REPO_URL="https://github.com/IvorySQL/IvorySQL.git"
BRANCH="IVORY_REL_4_STABLE"
LOG_DIR="/var/log/ivorysql"
EOF
)

# -------------------------- 步骤跟踪系统 --------------------------
CURRENT_STAGE() {
    echo -e "\n\033[34m[$(date '+%H:%M:%S')] $1\033[0m"
}

STEP_BEGIN() {
    echo -e "  → $1..."
}

STEP_SUCCESS() {
    echo -e "  \033[32m✓ $1\033[0m"
}

STEP_FAIL() {
    echo -e "  \033[31m✗ $1\033[0m" >&2
    exit 1
}

STEP_WARNING() {
    echo -e "  \033[33m⚠ $1\033[0m"
}

# -------------------------- 错误处理 --------------------------
handle_error() {
    local line=$1 command=$2
    STEP_FAIL "安装失败！位置: 第 ${line} 行\n命令: ${command}"
    echo "详细日志请查看: ${LOG_DIR}/error_${TIMESTAMP}.log"
    echo "请执行以下命令排查问题:"
    echo "1. systemctl status ivorysql.service"
    echo "2. journalctl -xe"
    echo "3. sudo -u ivorysql '${INSTALL_DIR}/bin/postgres -D ${DATA_DIR} -c logging_collector=on -c log_directory=${LOG_DIR}'"
    exit 1
}
trap 'handle_error ${LINENO} "${BASH_COMMAND}"' ERR

# -------------------------- 初始化配置 --------------------------
load_config() {
    CURRENT_STAGE "配置加载阶段"
    
    STEP_BEGIN "创建配置目录"
    mkdir -p /etc/ivorysql || STEP_FAIL "无法创建配置目录 /etc/ivorysql"
    STEP_SUCCESS "配置目录就绪"
    
    STEP_BEGIN "检查配置文件"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        STEP_WARNING "未找到配置文件，创建默认配置"
        echo "$DEFAULT_CONFIG" > "$CONFIG_FILE" || STEP_FAIL "无法写入配置文件 $CONFIG_FILE"
        chmod 600 "$CONFIG_FILE" || STEP_WARNING "权限设置失败（继续执行）"
        STEP_SUCCESS "默认配置已创建"
    else
        STEP_SUCCESS "发现现有配置文件"
    fi
    
    STEP_BEGIN "加载配置文件"
    source "$CONFIG_FILE" || STEP_FAIL "无法加载配置文件 $CONFIG_FILE"
    STEP_SUCCESS "配置文件加载成功"
    
    # 验证关键配置项
    STEP_BEGIN "验证配置完整性"
    declare -a required_vars=("INSTALL_DIR" "DATA_DIR" "SERVICE_USER" "SERVICE_GROUP")
    for var in "${required_vars[@]}"; do
        [[ -z "${!var}" ]] && STEP_FAIL "配置缺失: $var 未设置"
    done
    STEP_SUCCESS "配置完整性验证通过"
}

# -------------------------- 日志管理 --------------------------
init_logging() {
    CURRENT_STAGE "日志初始化"
    
    STEP_BEGIN "创建日志目录"
    mkdir -p "$LOG_DIR" || STEP_FAIL "无法创建日志目录 $LOG_DIR"
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$LOG_DIR"
    STEP_SUCCESS "日志目录已创建并设置权限"
    
    STEP_BEGIN "重定向输出流"
    exec > >(tee -a "${LOG_DIR}/install_${TIMESTAMP}.log")
    exec 2> >(tee -a "${LOG_DIR}/error_${TIMESTAMP}.log" >&2)
    STEP_SUCCESS "日志重定向完成"
}

# -------------------------- 权限检查 --------------------------
check_root() {
    CURRENT_STAGE "权限检查"
    
    STEP_BEGIN "验证用户权限"
    [[ "$(id -u)" -ne 0 ]] && { 
        STEP_FAIL "必须使用root权限运行此脚本"
        echo -e "请使用：\033[33msudo $0 $@\033[0m" >&2
        exit 1
    }
    STEP_SUCCESS "root权限验证通过"
}

# -------------------------- 环境检测 --------------------------
detect_environment() {
    CURRENT_STAGE "系统环境检测"
    
    STEP_BEGIN "识别操作系统"
    [[ ! -f /etc/os-release ]] && STEP_FAIL "无法确定操作系统类型"
    source /etc/os-release
    
    PKG_MANAGER=""
    STEP_SUCCESS "检测到操作系统: $PRETTY_NAME"
    
    case "$ID" in
        centos|rhel|almalinux|rocky)
            STEP_BEGIN "识别RHEL系版本"
            RHEL_VERSION=$(grep -Po '(?<=VERSION_ID=")[0-9]+' /etc/os-release | head -1)
            [[ -z $RHEL_VERSION ]] && STEP_FAIL "无法获取RHEL版本号"
            
            if [[ $RHEL_VERSION -eq 7 ]]; then
                STEP_FAIL "CentOS/RHEL 7请使用官方YUM源安装"
            elif [[ $RHEL_VERSION =~ ^(8|9)$ ]]; then
                PKG_MANAGER="dnf"
                if ! command -v dnf &>/dev/null; then
                    STEP_WARNING "dnf不可用，尝试使用yum"
                    PKG_MANAGER="yum"
                fi
                STEP_SUCCESS "使用包管理器: $PKG_MANAGER"
            else
                STEP_FAIL "不支持的RHEL系版本: $RHEL_VERSION"
            fi
            ;;
            
        ubuntu|debian)
            STEP_BEGIN "识别Debian系版本"
            UBUNTU_VERSION=$(grep -Po '(?<=VERSION_ID=")[0-9.]+' /etc/os-release)
            MAJOR_VERSION=${UBUNTU_VERSION%%.*}
            if [[ $MAJOR_VERSION =~ ^(18|20|22|24)$ ]]; then
                PKG_MANAGER="apt-get"
                STEP_SUCCESS "使用包管理器: $PKG_MANAGER"
            else
                STEP_FAIL "不支持的Ubuntu版本: $UBUNTU_VERSION"
            fi
            ;;
            
        opensuse*|sles)
            STEP_BEGIN "识别openSUSE/SLES"
            SLE_VERSION=$(grep -Po '(?<=VERSION_ID=")[0-9.]+' /etc/os-release)
            if [[ $SLE_VERSION =~ ^(15\.?|12\.5|42\.3) ]]; then
                PKG_MANAGER="zypper"
                STEP_SUCCESS "使用包管理器: $PKG_MANAGER"
            else
                STEP_FAIL "不支持的SUSE版本: $SLE_VERSION"
            fi
            ;;
            
        *)
            STEP_FAIL "不支持的操作系统: $ID"
            ;;
    esac
}

# -------------------------- 依赖管理 --------------------------
install_dependencies() {
    CURRENT_STAGE "安装系统依赖"
    
    local OFFICIAL_BASE_DEPS="bison readline-devel zlib-devel openssl-devel"
    
    declare -A OS_SPECIFIC_DEPS=(
        [rhel_base]="flex libicu-devel libxml2-devel python3-devel tcl-devel systemd-devel"
        [rhel_group]="Development Tools"
        [debian_base]="flex libreadline-dev libssl-dev zlib1g-dev libicu-dev"
        [debian_extra]="libxml2-dev python3-dev tcl-dev libsystemd-dev build-essential"
        [suse_base]="bison-devel readline-devel zlib-devel libopenssl-devel"
        [suse_extra]="flex libicu-devel libxml2-devel python3-devel tcl-devel systemd-devel"
    )

    case $ID in
        centos|rhel|almalinux|rocky)
            STEP_BEGIN "配置RHEL系依赖"
            $PKG_MANAGER install -y epel-release 2>/dev/null || STEP_WARNING "EPEL安装跳过 (可能已存在)"
            $PKG_MANAGER update -y || STEP_WARNING "系统更新跳过"
            
            $PKG_MANAGER install -y $OFFICIAL_BASE_DEPS || STEP_FAIL "基础依赖安装失败"
            
            if [[ "$PKG_MANAGER" == "dnf" ]]; then
                $PKG_MANAGER group install -y "${OS_SPECIFIC_DEPS[rhel_group]}" || STEP_FAIL "开发工具组安装失败"
            else
                $PKG_MANAGER groupinstall -y "Development Tools" || STEP_FAIL "开发工具组安装失败"
            fi
            
            $PKG_MANAGER install -y ${OS_SPECIFIC_DEPS[rhel_base]} || STEP_FAIL "额外依赖安装失败"
            STEP_SUCCESS "RHEL系依赖安装完成"
            ;;
            
        ubuntu|debian)
            STEP_BEGIN "配置Debian系依赖"
            export DEBIAN_FRONTEND=noninteractive
            $PKG_MANAGER update -y || STEP_WARNING "包列表更新跳过"
            
            local UBUNTU_BASE_DEPS=$(echo $OFFICIAL_BASE_DEPS | sed '
                s/readline-devel/libreadline-dev/g;
                s/zlib-devel/zlib1g-dev/g;
                s/openssl-devel/libssl-dev/g;
            ')
            
            $PKG_MANAGER install -y $UBUNTU_BASE_DEPS || STEP_FAIL "基础依赖安装失败"
            $PKG_MANAGER install -y ${OS_SPECIFIC_DEPS[debian_base]} ${OS_SPECIFIC_DEPS[debian_extra]} || STEP_FAIL "额外依赖安装失败"
            STEP_SUCCESS "Debian系依赖安装完成"
            ;;
            
        opensuse*|sles)
            STEP_BEGIN "配置SUSE系依赖"
            $PKG_MANAGER refresh || STEP_WARNING "软件源刷新跳过"
            $PKG_MANAGER install -y ${OS_SPECIFIC_DEPS[suse_base]} || STEP_FAIL "基础依赖安装失败"
            $PKG_MANAGER install -y ${OS_SPECIFIC_DEPS[suse_extra]} || STEP_FAIL "额外依赖安装失败"
            STEP_SUCCESS "SUSE系依赖安装完成"
            ;;
    esac
    
    STEP_BEGIN "验证必备工具"
    for cmd in gcc make flex bison; do
        if ! command -v $cmd >/dev/null 2>&1; then
            STEP_FAIL "必备工具缺失: $cmd"
        fi
        echo "检测到 $cmd: $(command -v $cmd)"
    done
    STEP_SUCCESS "所有编译工具就绪"
}

# -------------------------- 用户管理 --------------------------
setup_user() {
    CURRENT_STAGE "配置系统用户"
    
    STEP_BEGIN "创建用户组"
    if ! getent group "$SERVICE_GROUP" &>/dev/null; then
        groupadd "$SERVICE_GROUP" || STEP_FAIL "用户组创建失败"
        STEP_SUCCESS "用户组已创建: $SERVICE_GROUP"
    else
        STEP_SUCCESS "用户组已存在: $SERVICE_GROUP"
    fi

    STEP_BEGIN "创建用户"
    if ! id -u "$SERVICE_USER" &>/dev/null; then
        useradd -r -g "$SERVICE_GROUP" -s "/bin/bash" -m -d "/home/$SERVICE_USER" "$SERVICE_USER" || STEP_FAIL "用户创建失败"
        STEP_SUCCESS "用户已创建: $SERVICE_USER"
    else
        STEP_SUCCESS "用户已存在: $SERVICE_USER"
    fi
}

# -------------------------- 源码编译 --------------------------
compile_install() {
    CURRENT_STAGE "源码编译安装"
    
    local repo_dir=$(basename "$REPO_URL" .git)
    
    STEP_BEGIN "获取源代码"
    if [[ ! -d "IvorySQL" ]]; then
        git clone --depth 1 --branch "$BRANCH" "$REPO_URL" || STEP_FAIL "代码克隆失败"
        STEP_SUCCESS "代码库克隆完成"
    else
        STEP_SUCCESS "发现现有代码库"
    fi
    cd "IvorySQL" || STEP_FAIL "无法进入源码目录"
    
    STEP_BEGIN "切换到指定分支 ($BRANCH)"
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
        git reset --hard || STEP_WARNING "分支重置失败（继续执行）"
        git clean -fd || STEP_WARNING "清理失败（继续执行）"
        git checkout "$BRANCH" || STEP_FAIL "分支切换失败: $BRANCH"
        git pull origin "$BRANCH" || STEP_WARNING "代码更新失败（继续执行）"
        STEP_SUCCESS "已切换到分支: $BRANCH"
    else
        STEP_SUCCESS "当前已在分支: $BRANCH"
    fi
    
    COMMIT_ID=$(git rev-parse --short HEAD)
    STEP_SUCCESS "当前代码版本: $COMMIT_ID"
    
    STEP_BEGIN "配置编译参数"
    CONFIGURE_OPTS="--prefix=$INSTALL_DIR --with-openssl"
    
    [[ -f /usr/include/icu.h ]] && CONFIGURE_OPTS+=" --with-icu"
    [[ -f /usr/include/libxml2/libxml/parser.h ]] && CONFIGURE_OPTS+=" --with-libxml"
    
    ./configure $CONFIGURE_OPTS || STEP_FAIL "配置失败"
    STEP_SUCCESS "配置参数: $CONFIGURE_OPTS"
    
    STEP_BEGIN "编译源代码 (使用$(nproc)线程)"
    make -j$(nproc) || STEP_FAIL "编译失败"
    STEP_SUCCESS "编译完成"
    
    STEP_BEGIN "安装二进制文件"
    make install || STEP_FAIL "安装失败"
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR" || STEP_FAIL "安装目录权限设置失败"
    STEP_SUCCESS "成功安装到: $INSTALL_DIR"
}

# -------------------------- 后期配置 --------------------------
post_install() {
    CURRENT_STAGE "安装后配置"
    
    STEP_BEGIN "准备数据目录"
    mkdir -p "$DATA_DIR" || STEP_FAIL "无法创建数据目录 $DATA_DIR"
    
    if [ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
        STEP_BEGIN "清空非空数据目录"
        systemctl stop ivorysql 2>/dev/null || true
        rm -rf "${DATA_DIR:?}"/* "${DATA_DIR:?}"/.[^.]* "${DATA_DIR:?}"/..?* 2>/dev/null || true
        STEP_SUCCESS "数据目录已清空"
    else
        STEP_SUCCESS "数据目录为空（可直接使用）"
    fi
    
    chown "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR"
    chmod 750 "$DATA_DIR"
    STEP_SUCCESS "数据目录权限设置完成"

    STEP_BEGIN "配置环境变量"
    user_home=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
    cat > "$user_home/.bash_profile" <<EOF
# --- IvorySQL Environment Configuration ---
PATH="$INSTALL_DIR/bin:\$PATH"
export PATH
PGDATA="$DATA_DIR"
export PGDATA
# --- End of Configuration ---
EOF
    chown "$SERVICE_USER:$SERVICE_GROUP" "$user_home/.bash_profile"
    chmod 600 "$user_home/.bash_profile"
    
    su - "$SERVICE_USER" -c "source ~/.bash_profile" || STEP_WARNING "环境变量立即生效失败（继续执行）"
    STEP_SUCCESS "环境变量已设置"

    STEP_BEGIN "初始化数据库"
    INIT_CMD="initdb -D $DATA_DIR --no-locale"
    if ! su - "$SERVICE_USER" -c "source ~/.bash_profile && $INIT_CMD"; then
        STEP_FAIL "数据库初始化失败"
        echo "手动调试命令: sudo -u $SERVICE_USER bash -c 'source ~/.bash_profile && initdb -D $DATA_DIR --debug'"
        exit 1
    fi
    STEP_SUCCESS "数据库初始化完成"
    
    STEP_BEGIN "配置系统服务"
cat > /etc/systemd/system/ivorysql.service <<EOF
[Unit]
Description=IvorySQL Database Server
Documentation=https://www.ivorysql.org
Requires=network.target local-fs.target
After=network.target local-fs.target

[Service]
Type=forking
User=$SERVICE_USER
Group=$SERVICE_GROUP
Environment=PGDATA=$DATA_DIR
OOMScoreAdjust=-1000
ExecStart=$INSTALL_DIR/bin/pg_ctl start -D \${PGDATA} -s -w -t 60
ExecStop=$INSTALL_DIR/bin/pg_ctl stop -D \${PGDATA} -s -m fast
ExecReload=$INSTALL_DIR/bin/pg_ctl reload -D \${PGDATA}
TimeoutSec=0
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ivorysql
    STEP_SUCCESS "服务配置完成"
}

# -------------------------- 安装验证 --------------------------
verify_installation() {
    CURRENT_STAGE "安装验证"
    
    STEP_BEGIN "启动数据库服务"
    systemctl start ivorysql || {
        STEP_FAIL "服务启动失败"
        echo "======= 服务状态 ======="
        systemctl status ivorysql -l --no-pager
        echo "======= 最近日志 ======="
        journalctl -u ivorysql -n 50 --no-pager
        exit 1
    }
    STEP_SUCCESS "服务启动成功"

    STEP_BEGIN "监控服务状态"
    for i in {1..15}; do
        if systemctl is-active --quiet ivorysql; then
            STEP_SUCCESS "服务运行中"
            break
        fi
        [[ $i -eq 15 ]] && {
            STEP_FAIL "服务启动超时"
            journalctl -u ivorysql -n 100 --no-pager >&2
            exit 1
        }
        sleep 1
    done
    
    echo -e "\n\033[32m================ 安装成功 ================\033[0m"
    cat <<EOF
安装目录: $INSTALL_DIR
数据目录: $DATA_DIR
日志目录: $LOG_DIR
服务状态: $(systemctl is-active ivorysql)
数据库版本: $(${INSTALL_DIR}/bin/postgres --version)

管理命令: 
  systemctl [start|stop|status] ivorysql
  journalctl -u ivorysql -f
  sudo -u ivorysql '${INSTALL_DIR}/bin/psql'

安装时间: $(date)
安装耗时: $SECONDS 秒
EOF
}

# -------------------------- 主流程 --------------------------
main() {
    echo -e "\n\033[36m=========================================\033[0m"
    echo -e "\033[36m         IvorySQL 自动化安装脚本\033[0m"
    echo -e "\033[36m=========================================\033[0m"
    echo "脚本启动时间: $(date)"
    echo "安装标识号: $TIMESTAMP"
    
    check_root
    load_config
    setup_user
    init_logging
    detect_environment
    install_dependencies
    compile_install
    post_install
    verify_installation
}

main "$@"