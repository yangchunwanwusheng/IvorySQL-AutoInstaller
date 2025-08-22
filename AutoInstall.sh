#!/bin/bash
set -eo pipefail

CONFIG_FILE="/etc/ivorysql/install.conf"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OS_TYPE=""
OS_VERSION=""
XML_SUPPORT=0  # XML支持状态：0-禁用，1-启用

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

validate_config() {
    local key=$1 value=$2
    
    case $key in
        INSTALL_DIR|DATA_DIR|LOG_DIR)
            if [[ ! "$value" =~ ^/[^[:space:]]+$ ]]; then
                STEP_FAIL "配置错误: $key 必须是绝对路径且不含空格 (当前值: '$value')"
            fi
            
            if [[ -e "$value" ]]; then
                if [[ -f "$value" ]]; then
                    STEP_FAIL "配置错误: $key 必须是目录路径，但检测到文件 (当前值: '$value')"
                fi
                
                if ! [[ -w "$value" ]]; then
                    if [[ -O "$value" ]]; then
                        STEP_FAIL "配置错误: $key 路径不可写 (当前用户无权限)"
                    else
                        STEP_FAIL "配置错误: $key 路径不可写 (需要 $USER 权限)"
                    fi
                fi
            else
                local parent_dir=$(dirname "$value")
                mkdir -p "$parent_dir" || STEP_FAIL "无法创建父目录: $parent_dir"
                if [[ ! -w "$parent_dir" ]]; then
                    STEP_FAIL "配置错误: $key 父目录不可写 (路径: '$parent_dir')"
                fi
            fi
            ;;
            
        SERVICE_USER|SERVICE_GROUP)
            local reserved_users="root bin daemon adm lp sync shutdown halt mail operator games ftp"
            if grep -qw "$value" <<< "$reserved_users"; then
                STEP_FAIL "配置错误: $key 禁止使用系统保留名称 (当前值: '$value')"
            fi
            
            if [[ ! "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$ ]]; then
                STEP_FAIL "配置极: $key 命名无效 (当前值: '$value')"
                echo "命名规则: 以字母或下划线开头，可包含字母、数字、下划线(_)和连字符(-)，长度1-32字符"
            fi
            
            if [[ $key == "SERVICE_USER" ]]; then
                if ! getent passwd "$value" &>/dev/null; then
                    STEP_SUCCESS "将创建新用户: $value"
                fi
            else
                if ! getent group "$value" &>/dev/null; then
                    STEP_SUCCESS "将创建新组: $value"
                fi
            fi
            ;;
            
        REPO_URL)
            if [[ ! "$value" =~ ^https?://[a-zA-Z0-9./_-]+$ ]]; then
                STEP_FAIL "配置错误: REPO_URL 格式无效 (当前值: '$value')"
            fi
            
            if [[ ! "$value" =~ github\.com/IvorySQL/IvorySQL ]]; then
                STEP_WARNING "警告: 使用的代码库可能不是官方源 ($value)"
                read -p "确认使用非官方源? (y/N) " -n 1 -r
                echo
                [[ ! $REPLY =~ ^[Yy]$ ]] && STEP_FAIL "安装中止：用户拒绝非官方源"
            fi
            ;;
            
        BRANCH|TAG)
            if [[ -n "$value" ]]; then
                if [[ "$value" =~ [\$\&\;\|\>\<\!\\\'\"] ]]; then
                    STEP_FAIL "配置错误: $key 包含危险字符 (当前值: '$value')"
                fi
                
                if [[ ${#value} -gt 100 ]]; then
                    STEP_WARNING "警告: $key 长度超过100字符 (当前值: '$value')"
                    read -p "确认使用超长标识? (y/N) " -n 1 -r
                    echo
                    [[ ! $REPLY =~ ^[Yy]$ ]] && STEP_FAIL "安装中止：用户拒绝超长标识"
                fi
            fi
            ;;
    esac
}

load_config() {
    CURRENT_STAGE "配置加载阶段"
    
    STEP_BEGIN "检查配置文件是否存在"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        STEP_FAIL "配置文件 $CONFIG_FILE 不存在，请根据模板创建配置文件"
    fi
    STEP_SUCCESS "发现配置文件"
    
    STEP_BEGIN "加载配置文件"
    source "$CONFIG_FILE" || STEP_FAIL "无法加载配置文件 $CONFIG_FILE"
    STEP_SUCCESS "配置文件加载成功"
    
    STEP_BEGIN "验证配置完整性"
    declare -a required_vars=("INSTALL_DIR" "DATA_DIR" "SERVICE_USER" "SERVICE_GROUP" "REPO_URL")
    for var in "${required_vars[@]}"; do
        [[ -z "${!var}" ]] && STEP_FAIL "配置缺失: $var 未设置"
    done
    STEP_SUCCESS "配置完整性验证通过"
    
    if [[ -z "$TAG" && -z "$BRANCH" ]]; then
        STEP_FAIL "必须设置 TAG 或 BRANCH 之一"
    elif [[ -n "$TAG" && -n "$BRANCH" ]]; then
        STEP_WARNING "同时设置了 TAG 和 BRANCH，将优先使用 TAG($TAG)"
    fi
    
    STEP_BEGIN "检查配置内容有效性"
    while IFS='=' read -r key value; do
        [[ $key =~ ^[[:space:]]*# || -z $key ]] && continue
        key=$(echo $key | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        validate_config "$key" "$value"
    done < "$CONFIG_FILE"
    STEP_SUCCESS "配置内容有效性验证通过"
}

init_logging() {
    CURRENT_STAGE "日志初始化"
    
    STEP_BEGIN "创建日志目录"
    mkdir -p "$LOG_DIR" || STEP_FAIL "无法创建日志目录 $LOG_DIR"
    
    # 只有在用户已存在的情况下才设置权限
    if id -u "$SERVICE_USER" &>/dev/null && getent group "$SERVICE_GROUP" &>/dev/null; then
        chown "$SERVICE_USER:$SERVICE_GROUP" "$LOG_DIR"
        STEP_SUCCESS "日志目录已创建并设置权限"
    else
        STEP_WARNING "用户/组不存在，跳过权限设置"
        STEP_SUCCESS "日志目录已创建"
    fi
    
    STEP_BEGIN "重定向输出流"
    exec > >(tee -a "${LOG_DIR}/install_${TIMESTAMP}.log")
    exec 2> >(tee -a "${LOG_DIR}/error_${TIMESTAMP}.log" >&2)
    STEP_SUCCESS "日志重定向完成"
}

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

detect_environment() {
    CURRENT_STAGE "系统环境检测"
    
    get_major_version() {
        grep -Eo 'VERSION_ID="?[0-9.]+' /etc/os-release | 
        cut -d= -f2 | tr -d '"' | cut -d. -f1
    }

    STEP_BEGIN "识别操作系统"
    [[ ! -f /etc/os-release ]] && STEP_FAIL "无法确定操作系统类型"
    source /etc/os-release
    
    OS_TYPE="$ID"
    OS_VERSION="$VERSION_ID"
    
    PKG_MANAGER=""
    STEP_SUCCESS "检测到操作系统: $PRETTY_NAME"
    
    # 专门处理Oracle Linux
    if [[ -f /etc/oracle-release ]]; then
        OS_TYPE="oracle"
        ORACLE_VERSION=$(grep -oE '([0-9]+)\.?([0-9]+)?' /etc/oracle-release | head -1)
        STEP_SUCCESS "检测到Oracle Linux $ORACLE_VERSION"
    fi
    
    case "$OS_TYPE" in
        centos|rhel|almalinux|rocky|fedora|oracle)
            RHEL_VERSION=$(get_major_version)
            [[ -z $RHEL_VERSION ]] && STEP_FAIL "无法获取版本号"
            
            if [[ $RHEL_VERSION -eq 7 ]]; then
                STEP_FAIL "CentOS/RHEL 7请使用官方YUM源安装"
            elif [[ $RHEL_VERSION =~ ^(8|9|10)$ ]]; then
                if command -v dnf &>/dev/null; then
                    PKG_MANAGER="dnf"
                    STEP_SUCCESS "使用包管理器: dnf"
                else
                    PKG_MANAGER="yum"
                    STEP_WARNING "dnf不可用，使用yum替代"
                fi
            else
                STEP_FAIL "不支持的版本: $RHEL_VERSION"
            fi
            ;;
            
        ubuntu|debian)
            OS_VERSION=$(grep -Po '(?<=VERSION_ID=")[0-9.]+' /etc/os-release)
            MAJOR_VERSION=${OS_VERSION%%.*}
            
            case "$OS_TYPE" in
                ubuntu)
                    [[ $MAJOR_VERSION =~ ^(18|20|22|24)$ ]] || 
                    STEP_FAIL "不支持的Ubuntu版本: $OS_VERSION" ;;
                debian)
                    [[ $MAJOR_VERSION =~ ^(10|11|12)$ ]] || 
                    STEP_FAIL "不支持的Debian版本: $OS_VERSION" ;;
            esac
            
            PKG_MANAGER="apt-get"
            STEP_SUCCESS "使用包管理器: apt-get"
            ;;
            
        opensuse*|sles)
            SLE_VERSION=$(grep -Po '(?<=VERSION_ID=")[0-9.]+' /etc/os-release)
            
            if [[ "$ID" == "opensuse-leap" ]]; then
                [[ $SLE_VERSION =~ ^15 ]] || STEP_FAIL "不支持的openSUSE Leap版本"
            elif [[ "$ID" == "sles" ]]; then
                [[ $SLE_VERSION =~ ^(12\.5|15) ]] || STEP_FAIL "不支持的SLES版本"
            else
                STEP_FAIL "未知的SUSE变体"
            fi
            
            PKG_MANAGER="zypper"
            STEP_SUCCESS "使用包管理器: zypper"
            ;;
            
        arch)
            PKG_MANAGER="pacman"
            STEP_SUCCESS "Arch Linux 已支持" ;;
            
        *)
            if [[ -f /etc/redhat-release ]]; then
                STEP_FAIL "未知的RHEL兼容发行版"
            elif [[ -f /etc/debian_version ]]; then
                STEP_FAIL "未知的Debian兼容发行版"
            else
                STEP_FAIL "无法识别的Linux发行版"
            fi
            ;;
    esac
}

install_dependencies() {
    CURRENT_STAGE "安装系统依赖"
    
    declare -A OS_SPECIFIC_DEPS=(
        [rhel_base]="zlib-devel openssl-devel perl-ExtUtils-Embed"
        [rhel_tools]="gcc make flex bison"
        [rhel_group]="Development Tools"
        [perl_deps]="perl-Test-Simple perl-Data-Dumper perl-devel"
        [libxml_dep]="libxml2-devel"
        [debian_base]="zlib1g-dev libssl-dev"
        [debian_tools]="build-essential flex bison"
        [debian_libxml]="libxml2-dev"
        [suse_base]="zlib-devel libopenssl-devel"
        [suse_tools]="gcc make flex bison"
        [suse_libxml]="libxml2-devel"
        [arch_base]="zlib openssl perl"
        [arch_tools]="base-devel"
        [arch_libxml]="libxml2"
    )

    STEP_BEGIN "更新软件源"
    case "$OS_TYPE" in
        centos|rhel|almalinux|rocky|fedora)
            $PKG_MANAGER install -y epel-release 2>/dev/null || true
            if [[ $RHEL_VERSION -eq 10 ]]; then
                STEP_BEGIN "为EL10启用CRB仓库"
                if [[ "$ID" == "rocky" ]]; then
                    $PKG_MANAGER config-manager --set-enabled crb || true
                elif [[ "$ID" == "ol" || "$ID" == "oracle" ]]; then
                    # Oracle Linux 10特定仓库处理
                    STEP_BEGIN "启用Oracle Linux 10开发者仓库"
                    if $PKG_MANAGER repolist | grep -q "ol10_developer"; then
                        $PKG_MANAGER config-manager --enable ol10_developer || true
                    elif $PKG_MANAGER repolist | grep -q "ol10_addons"; then
                        $PKG_MANAGER config-manager --enable ol10_addons || true
                    fi
                    STEP_SUCCESS "仓库已配置"
                else
                    $PKG_MANAGER config-manager --set-enabled codeready-builder || true
                fi
                STEP_SUCCESS "仓库配置完成"
            fi
            
            $PKG_MANAGER update -y || true
            ;;
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            $PKG_MANAGER update -y || true
            ;;
        opensuse*|sles)
            $PKG_MANAGER refresh || true
            ;;
        arch)
            pacman -Syu --noconfirm
            ;;
    esac
    STEP_SUCCESS "软件源更新完成"

    STEP_BEGIN "安装核心依赖"
    case "$OS_TYPE" in
        centos|rhel|almalinux|rocky|fedora|oracle)
            # Oracle Linux 专用设置 - 修复行57错误
            if [[ "$OS_TYPE" == "oracle" ]]; then
                STEP_BEGIN "安装Oracle Linux特定依赖"
                $PKG_MANAGER install -y oraclelinux-developer-release-el${RHEL_VERSION} 2>/dev/null || true
                $PKG_MANAGER group install -y "Development Tools" 2>/dev/null || true
                STEP_SUCCESS "Oracle特定依赖处理完成"
            fi
            
            # 通用EL依赖安装
            if [[ "$PKG_MANAGER" == "dnf" ]]; then
                $PKG_MANAGER group install -y "${OS_SPECIFIC_DEPS[rhel_group]}" || true
            else
                $PKG_MANAGER groupinstall -y "${OS_SPECIFIC_DEPS[rhel_group]}" || true
            fi
            
            # 强制安装readline-devel（必须安装）
            STEP_BEGIN "安装readline开发包（必须）"
            $PKG_MANAGER install -y readline-devel || STEP_FAIL "readline-devel安装失败，必须安装readline开发包"
            STEP_SUCCESS "readline开发包安装成功"
            
            $PKG_MANAGER install -y \
                ${OS_SPECIFIC_DEPS[rhel_base]} \
                ${OS_SPECIFIC_DEPS[perl_deps]} \
                ${OS_SPECIFIC_DEPS[libxml_dep]} \
                tcl-devel libicu-devel || true
            ;;
        ubuntu|debian)
            # 强制安装libreadline-dev（必须安装）
            STEP_BEGIN "安装libreadline-dev（必须）"
            $PKG_MANAGER install -y libreadline-dev || STEP_FAIL "libreadline-dev安装失败，必须安装readline开发包"
            STEP_SUCCESS "readline开发包安装成功"
            
            $PKG_MANAGER install -y \
                ${OS_SPECIFIC_DEPS[debian_tools]} \
                ${OS_SPECIFIC_DEPS[debian_base]} \
                ${OS_SPECIFIC_DEPS[debian_libxml]} \
                libperl-dev perl-modules || true
            ;;
        opensuse*|sles)
            # 强制安装readline-devel（必须安装）
            STEP_BEGIN "安装readline-devel（必须）"
            $PKG_MANAGER install -y readline-devel || STEP_FAIL "readline-devel安装失败，必须安装readline开发包"
            STEP_SUCCESS "readline开发包安装成功"
            
            $PKG_MANAGER install -y \
                ${OS_SPECIFIC_DEPS[suse_tools]} \
                ${OS_SPECIFIC_DEPS[suse_base]} \
                ${OS_SPECIFIC_DEPS[s极libxml]} \
                perl-devel perl-ExtUtils-Embed || true
            ;;
        arch)
            # 强制安装readline（必须安装）
            STEP_BEGIN "安装readline（必须）"
            pacman -S --noconfirm readline || STEP_FAIL "readline安装失败，必须安装readline开发包"
            STEP_SUCCESS "readline开发包安装成功"
            
            pacman -S --noconfirm \
                ${OS_SPECIFIC_DEPS[arch_base]} \
                ${OS_SPECIFIC_DEPS[arch_tools]} \
                ${OS_SPECIFIC_DEPS[arch_libxml]} || true
            ;;
    esac
    STEP_SUCCESS "核心依赖安装完成"

    # 安装必需的 Perl 模块
    STEP_BEGIN "安装必需的 Perl 模块"
    case "$OS_TYPE" in
        centos|rhel|almalinux|rocky|fedora|oracle)
            # 安装 Perl 核心模块和开发工具
            $PKG_MANAGER install -y perl-core perl-devel || true
            
            # 尝试安装 IPC-Run
            if ! $PKG_MANAGER install -y perl-IPC-Run 2>/dev/null; then
                STEP_WARNING "perl-IPC-Run 包不可用，尝试通过 CPAN 安装"
                # 使用 CPAN 安装缺失的模块
                cpan -i IPC::Run FindBin || {
                    STEP_WARNING "CPAN 安装失败，尝试其他方法"
                    # 如果 CPAN 不可用，尝试使用 cpanm
                    curl -L https://cpanmin.us | perl - App::cpanminus || true
                    cpanm IPC::Run FindBin || STEP_WARNING "Perl 模块安装可能不完整"
                }
            fi
            ;;
        ubuntu|debian)
            $PKG_MANAGER install -y perl-modules libipc-run-perl || true
            ;;
        opensuse*|sles)
            $PKG_MANAGER install -y perl-IPC-Run || true
            ;;
        arch)
            pacman -S --noconfirm perl-ipc-run || true
            ;;
    esac
    STEP_SUCCESS "Perl 模块安装完成"

    STEP_BEGIN "验证编译工具"
    for cmd in gcc make flex bison; do
        if ! command -v $cmd >/dev/null 2>&1; then
            STEP_WARNING "工具缺失: $cmd (将尝试继续编译)"
        else
            echo "检测到 $cmd: $(command -v $cmd)"
        fi
    done
    
    if ! command -v perl >/dev/null 2>&1; then
        STEP_WARNING "警告: Perl解释器未找到，但将继续编译"
    else
        echo "检测到 Perl: $(command -v perl)"
        echo "Perl版本: $(perl --version | head -n 2 | tail -n 1)"
    fi
    
    # XML支持强化检测
    STEP_BEGIN "检测XML支持"
    if [[ -f /usr/include/libxml2/libxml/parser.h || -f /usr/include/libxml/parser.h ]]; then
        XML_SUPPORT=1
        STEP_SUCCESS "XML开发库已找到，将启用XML支持"
    else
        XML_SUPPORT=0
        STEP_WARNING "XML开发库未找到，将禁用XML支持"
    fi
    
    # 确保LibXML2开发库存在
    if [[ $XML_SUPPORT -eq 0 ]]; then
        STEP_BEGIN "尝试安装LibXML2开发包"
        case "$OS_TYPE" in
            centos|rhel|almalinux|rocky|oracle)
                $PKG_MANAGER install -y libxml2-devel || true ;;
            ubuntu|debian)
                $PKG_MANAGER install -y libxml2-dev || true ;;
            opensuse*|sles)
                $PKG_MANAGER install -y libxml2-devel || true ;;
            arch)
                pacman -S --noconfirm libxml2 || true ;;
        esac
        
        # 重新检查
        if [[ -f /usr/include/libxml2/libxml/parser.h || -f /usr/include/libxml/parser.h ]]; then
            XML_SUPPORT=1
            STEP_SUCCESS "XML开发库安装成功，启用XML支持"
        else
            XML_SUPPORT=0
            STEP_WARNING "XML开发库安装失败，将禁用XML支持"
        fi
    fi
    STEP_SUCCESS "编译工具验证完成"
}

setup_user() {
    CURRENT_STAGE "配置系统用户"
    
    STEP_BEGIN "创建用户组"
    if ! getent group "$SERVICE_GROUP" &>/dev/null; then
        groupadd "$SERVICE_GROUP" || {
            # 如果标准组创建失败，尝试使用不同的方法
            STEP_WARNING "标准组创建失败，尝试替代方法"
            groupadd -r "$SERVICE_GROUP" || STEP_FAIL "用户组创建失败"
        }
        STEP_SUCCESS "用户组已创建: $SERVICE_GROUP"
    else
        STEP_SUCCESS "用户组已存在: $SERVICE_GROUP"
    fi

    STEP_BEGIN "创建用户"
    if ! id -u "$SERVICE_USER" &>/dev/null; then
        # 尝试多种用户创建方法以适应不同系统
        useradd -r -g "$SERVICE_GROUP" -s "/bin/bash" -m -d "/home/$SERVICE_USER" "$SERVICE_USER" || 
        useradd -r -g "$SERVICE_GROUP" -s "/bin/bash" "$SERVICE_USER" || 
        useradd -g "$SERVICE_GROUP" -s "/bin/bash" -m -d "/home/$SERVICE_USER" "$SERVICE_USER" || 
        STEP_FAIL "用户创建失败"
        STEP_SUCCESS "用户已创建: $SERVICE_USER"
    else
        STEP_SUCCESS "用户已存在: $SERVICE_USER"
    fi
    
    # 额外验证步骤
    STEP_BEGIN "验证用户和组配置"
    if ! id -u "$SERVICE_USER" &>/dev/null; then
        STEP_FAIL "用户验证失败: $SERVICE_USER"
    fi
    
    if ! getent group "$SERVICE_GROUP" &>/dev/null; then
        STEP_FAIL "用户组验证失败: $SERVICE_GROUP"
    fi
    STEP_SUCCESS "用户和组验证成功"
}

compile_install() {
    CURRENT_STAGE "源码编译安装"
    
    local repo_dir=$(basename "$REPO_URL" .git)
    
    STEP_BEGIN "获取源代码"
    if [[ ! -d "IvorySQL" ]]; then
        git_clone_cmd="git clone"
        
        if [[ -n "$TAG" ]]; then
            STEP_BEGIN "使用标签获取代码 ($TAG)"
            git_clone_cmd+=" -b $TAG"
        elif [[ -n "$BRANCH" ]]; then
            STEP_BEGIN "使用分支获取代码 ($BRANCH)"
            git_clone_cmd+=" -b $BRANCH"
        fi
        
        git_clone_cmd+=" --progress $REPO_URL"
        
        echo "执行命令: $git_clone_cmd"
        # 添加重试机制和备用方案
        for i in {1..3}; do
            if $git_clone_cmd; then
                break
            fi
            if [[ $i -eq 3 ]]; then
                STEP_FAIL "代码克隆失败，请检查网络连接和仓库地址"
            fi
            STEP_WARNING "克隆尝试 $i/3 失败，10秒后重试..."
            sleep 10
        done
        STEP_SUCCESS "代码库克隆完成"
    else
        STEP_SUCCESS "发现现有代码库"
    fi
    cd "IvorySQL" || STEP_FAIL "无法进入源码目录"
    
    if [[ -n "$TAG" ]]; then
        STEP_BEGIN "验证标签 ($TAG)"
        git checkout tags/"$TAG" --progress || STEP_FAIL "标签切换失败: $TAG"
        COMMIT_ID=$(git rev-parse --short HEAD)
        STEP_SUCCESS "标签 $TAG (commit: $COMMIT_ID)"
    else
        STEP_BEGIN "切换到指定分支 ($BRANCH)"
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
            git reset --hard || STEP_WARNING "分支重置失败（继续执行）"
            git clean -fd || STEP_WARNING "清理失败（继续执行）"
            git checkout "$BRANCH" --progress || STEP_FAIL "分支切换失败: $BRANCH"
            git pull origin "$BRANCH" --progress || STEP_WARNING "代码更新失败（继续执行）"
            STEP_SUCCESS "已切换到分支: $BRANCH"
        else
            STEP_SUCCESS "当前已在分支: $BRANCH"
        fi
        COMMIT_ID=$(git rev-parse --short HEAD)
        STEP_SUCCESS "当前代码版本: $COMMIT_ID"
    fi
    
    # 验证 Perl 环境完整性
    STEP_BEGIN "验证 Perl 环境完整性"
    REQUIRED_PERL_MODULES=("FindBin" "IPC::Run")
    MISSING_MODULES=()

    for module in "${REQUIRED_PERL_MODULES[@]}"; do
        if ! perl -M"$module" -e 1 2>/dev/null; then
            MISSING_MODULES+=("$module")
        fi
    done

    if [ ${#MISSING_MODULES[@]} -ne 0 ]; then
        STEP_WARNING "缺少 Perl 模块: ${MISSING_MODULES[*]}"
        STEP_BEGIN "尝试安装缺失的 Perl 模块"
        for module in "${MISSING_MODULES[@]}"; do
            if command -v cpanm >/dev/null 2>&1; then
                cpanm "$module" || STEP_WARNING "无法安装 $module"
            else
                cpan "$module" || STEP_WARNING "无法安装 $module"
            fi
        done
        STEP_SUCCESS "Perl 模块安装尝试完成"
    fi

    # 重新检查
    for module in "${REQUIRED_PERL_MODULES[@]}"; do
        if ! perl -M"$module" -e 1 2>/dev/null; then
            STEP_FAIL "必需的 Perl 模块 $module 仍然缺失，编译将失败"
        fi
    done
    STEP_SUCCESS "Perl 环境验证通过"
    
    STEP_BEGIN "配置编译参数"
    # 基础配置选项 - 直接启用readline（已确保安装）
    CONFIGURE_OPTS="--prefix=$INSTALL_DIR --with-openssl --with-readline"
    STEP_SUCCESS "启用readline支持"
    
    # 检测ICU
    icu_paths=("/usr/include/unicode/utypes.h" "/usr/include/icu.h")
    if [[ -f "${icu_paths[0]}" || -f "${icu_paths[1]}" ]]; then
        CONFIGURE_OPTS+=" --with-icu"
        STEP_SUCCESS "ICU开发环境完整，启用支持"
    else
        CONFIGURE_OPTS+=" --without-icu"
        STEP_WARNING "ICU库未找到，已禁用ICU支持"
    fi
    
    # XML支持配置
    if [[ $XML_SUPPORT -eq 1 ]]; then
        CONFIGURE_OPTS+=" --with-libxml"
        STEP_SUCCESS "XML开发环境完整，启用支持"
    else
        CONFIGURE_OPTS+=" --without-libxml"
        STEP_WARNING "XML开发库未找到，已禁用XML支持"
    fi
    
    # 检测TCL
    tcl_paths=("/usr/include/tcl.h" "/usr/include/tcl8.6/tcl.h")
    if [[ -f "${tcl_paths[0]}" || -f "${tcl_paths[1]}" ]]; then
        CONFIGURE_OPTS+=" --with-tcl"
        STEP_SUCCESS "TCL开发环境完整，启用支持"
    else
        CONFIGURE_OPTS+=" --without-tcl"
        STEP_WARNING "TCL开发环境未找到，已禁用TCL扩展"
    fi
    
    # 检测Perl
    perl_paths=("/usr/bin/perl" "/usr/local/bin/perl")
    if command -v perl >/dev/null; then
        perl_header=$(find /usr -name perl.h 2>/dev/null | head -n1)
        if [[ -n "$perl_header" ]]; then
            CONFIGURE_OPTS+=" --with-perl"
            STEP_SUCCESS "Perl开发环境完整，启用支持"
        else
            CONFIGURE_OPTS+=" --without-perl"
            STEP_WARNING "Perl头文件缺失 (perl.h未找到)，禁用支持"
        fi
    else
        STEP_WARNING "未检测到Perl解释器，禁用Perl支持"
        CONFIGURE_OPTS+=" --without-perl"
    fi
    
    echo "最终配置参数: $CONFIGURE_OPTS"
    ./configure $CONFIGURE_OPTS || {
        STEP_FAIL "配置失败"
        echo "配置日志:"
        tail -20 config.log
        exit 1
    }
    STEP_SUCCESS "配置完成"
    
    STEP_BEGIN "编译源代码 (使用$(nproc)线程)"
    make -j$(nproc) || STEP_FAIL "编译失败"
    STEP_SUCCESS "编译完成"
    
    STEP_BEGIN "安装二进制文件"
    make install || STEP_FAIL "安装失败"
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR" || STEP_FAIL "安装目录权限设置失败"
    STEP_SUCCESS "成功安装到: $INSTALL_DIR"
}

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
PATH="$INSTALL_DIR/bin:\$PATH"
export PATH
PGDATA="$DATA_DIR"
export PGDATA
EOF
    chown "$SERVICE_USER:$SERVICE_GROUP" "$user_home/.bash_profile"
    chmod 600 "$user_home/.bash_profile"
    
    su - "$SERVICE_USER" -c "source ~/.bash_profile" || STEP_WARNING "环境变量立即生效失败（继续执行）"
    STEP_SUCCESS "环境变量已设置"

    STEP_BEGIN "初始化数据库"
    INIT_LOG="${LOG_DIR}/initdb_${TIMESTAMP}.log"
    INIT_CMD="source ~/.bash_profile && initdb -D $DATA_DIR --no-locale --debug"
    
    # 如果XML支持不可用，禁用相关扩展
    if [[ $XML_SUPPORT -eq 0 ]]; then
        INIT_CMD+=" --no-ivorysql-ora"
        STEP_WARNING "XML支持缺失，禁用ivorysql_ora扩展"
    fi
    
    if ! su - "$SERVICE_USER" -c "$INIT_CMD" > "$INIT_LOG" 2>&1; then
        STEP_FAIL "数据库初始化失败"
        echo "======= 初始化日志 ======="
        tail -n 50 "$INIT_LOG"
        echo "=========================="
        echo "手动调试命令: sudo -u $SERVICE_USER bash -c 'source ~/.bash_profile && initdb -D $DATA_DIR --debug'"
        exit 1
    fi
    
    if grep -q "FATAL" "$INIT_LOG"; then
        STEP_FAIL "数据库初始化过程中检测到错误"
        echo "======= 错误详情 ======="
        grep -A 10 "FATAL" "$INIT_LOG"
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
Environment=LD_LIBRARY_PATH=$INSTALL_DIR/lib:$INSTALL_DIR/lib/postgresql
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
    
    # 验证扩展是否正常工作
    STEP_BEGIN "验证扩展功能"
    if sudo -u $SERVICE_USER $INSTALL_DIR/bin/psql -d postgres -c "SELECT * FROM pg_available_extensions WHERE name = 'ivorysql_ora'" | grep -q ivorysql_ora; then
        STEP_SUCCESS "ivorysql_ora扩展已成功加载"
    else
        if [[ $XML_SUPPORT -eq 0 ]]; then
            STEP_WARNING "ivorysql_ora扩展未加载（因XML支持缺失）"
        else
            STEP_WARNING "ivorysql_ora扩展未能加载，请检查日志"
        fi
    fi
    
    # 显示成功信息
    show_success_message
}

show_success_message() {
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

安装标识号: $TIMESTAMP
操作系统: $OS_TYPE $OS_VERSION
EOF
    if [[ $XML_SUPPORT -eq 0 ]]; then
        echo -e "\033[33m注意: XML支持未启用，部分功能受限\033[0m"
    fi
}

main() {
    echo -e "\n\033[36m=========================================\033[0m"
    echo -e "\033[36m         IvorySQL 自动化安装脚本\033[0m"
    echo -e "\033[36m=========================================\033[0m"
    echo "脚本启动时间: $(date)"
    echo "安装标识号: $TIMESTAMP"
    echo "特别注意: 包含Perl模块修复和跨平台优化"
    
    SECONDS=0
    check_root          # 1. 检查root权限
    load_config         # 2. 加载配置
    detect_environment  # 3. 检测环境
    setup_user          # 4. 创建用户和组
    init_logging        # 5. 初始化日志
    install_dependencies # 6. 安装依赖
    compile_install     # 7. 编译安装
    post_install        # 8. 安装后配置
    verify_installation # 9. 验证安装
}

main "$@"
