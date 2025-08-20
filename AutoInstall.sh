#!/bin/bash
set -eo pipefail

CONFIG_FILE="/etc/ivorysql/install.conf"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

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
    echo -e "  \033[33m⚠ $极\033[0m"
}

STEP_INFO() {
    echo -e "  \033[36mℹ $1\033[0m"
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
                STEP_FAIL "配置错误: $key 命名无效 (当前值: '$value')"
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
    
    # 修复第 146 行问题：替换错误字符 "极" 为正确的 "-z"
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
    
    chown "$SERVICE_USER:$SERVICE_GROUP" "$LOG_DIR"
    STEP_SUCCESS "日志目录已创建并设置权限"
    
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
    CURRENT_STAGE "极环境检测"
    
    get_major_version() {
        grep -Eo 'VERSION_ID="?[0-9.]+' /etc/os-release | 
        cut -d= -f2 | tr -d '"' | cut -d. -f1
    }

    STEP_BEGIN "识别操作系统"
    [[ ! -f /etc/os-release ]] && STEP_FAIL "无法确定操作系统类型"
    source /etc/os-release
    
    PKG_MANAGER=""
    STEP_SUCCESS "检测到操作系统: $PRETTY_NAME"
    
    case "$ID" in
        centos|rhel|almalinux|rocky|ol|fedora)  # 添加ol(Oracle Linux)
            RHEL_VERSION=$(get_major_version)
            [[ -z $RHEL_VERSION ]] && STEP_FAIL "无法获取版本号"
            
            # ==== EL10支持增强 ====
            if [[ $RHEL_VERSION -eq 7 ]]; then
                STEP_FAIL "CentOS/RHEL 7请使用官方YUM源安装"
            elif [[ $RHEL_VERSION =~ ^(8|9|10)$ ]]; then
                if command -v dnf &>/dev/null; then
                    PKG_MANAGER="dnf"
                else
                    PKG_MANAGER="yum"
                    STEP_WARNING "dnf不可用，使用yum替代"
                fi
                
                # EL10专用提示信息
                if [[ $RHEL_VERSION -eq 10 ]]; then
                    case "$ID" in
                        rhel)    EL_TYPE="Red Hat Enterprise Linux 10" ;;
                        rocky)   EL_TYPE="Rocky Linux 10" ;;
                        almalinux) EL_TYPE="AlmaLinux 10" ;;
                        ol)      EL_TYPE="Oracle Linux 10" ;;
                        *)       EL_TYPE="RHEL 10兼容系统" ;;
                    esac
                    
                    STEP_SUCCESS "检测到 EL10 版本: $EL_TYPE"
                    
                    # 根据图片信息添加维护主体说明
                    case "$ID" in
                        rocky)   STEP_INFO "维护主体: Rocky Enterprise Software Foundation" ;;
                        almalinux) STEP_INFO "维护主体: CloudLinux" ;;
                        ol)      STEP_INFO "维护主体: Oracle" ;;
                    esac
                    
                    # 十年维护周期提示
                    STEP_INFO "提供10年维护周期支持 (2024-2034)"
                    
                    # Oracle Linux内核信息
                    if [[ "$ID" == "ol" ]]; then
                        if uname -r | grep -q 'uek'; then
                            STEP_INFO "内核类型: UEK (Unbreakable Enterprise Kernel)"
                        else
                            STEP_INFO "内核类型: RHEL兼容内核"
                        fi
                    fi
                fi
                STEP_SUCCESS "使用包管理器: $PKG_MANAGER"
            else
                STEP_FAIL "不支持的版本: $RHEL_VERSION"
            fi
            ;;
            
        ubuntu|debian)
            OS_VERSION=$(grep -Po '(?<=VERSION_ID=")[0-9.]+' /etc/os-release)
            MAJOR_VERSION=${OS_VERSION%%.*}
            
            case "$ID" in
                ubuntu)
                    [[ $MAJOR_VERSION =~ ^(18|20|22|24)$ ]] || 
                    STEP_FAIL "不支持的Ubuntu版本: $OS_VERSION" ;;
                debian)
                    [[ $MAJOR_VERSION =~ ^(10|11|12)$ ]] || 
                    STEP_FAIL "不支持的Debian版本: $OS_VERSION" ;;
            esac
            
            PKG_MANAGER="apt-get"
            STEP_SUCCESS "使用包管理器: $PKG_MANAGER"
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
            STEP_SUCCESS "使用包管理器: $PKG_MANAGER"
            ;;
            
        arch)
            PKG_MANAGER="pacman"
            STEP_SUCCESS "Arch Linux 已支持" ;;
            
        *)
            if [[ -f /etc/redhat-release ]]; then
                # 尝试解析redhat-release文件
                if grep -qi "release 10" /etc/redhat-release; then
                    PKG_MANAGER="dnf"
                    STEP_SUCCESS "检测到RHEL兼容版10(基于/etc/redhat-release)"
                else
                    STEP_FAIL "未知的RHEL兼容发行版"
                fi
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
        [rhel_base]="readline-devel zlib-devel openssl-devel"
        [rhel_tools]="gcc make flex bison"
        [rhel_group]="Development Tools"
        [debian_base]="libreadline-dev zlib1g-dev libssl-dev"
        [debian_tools]="build-essential flex bison"
        [suse_base]="readline-devel zlib-devel libopenssl-devel"
        [suse_tools]="gcc make flex bison"
        
        # EL10专用依赖
        [el10_special]="libicu libxml2 libxslt"
        
        # Perl相关依赖
        [perl_base]="perl perl-devel perl-CPAN"
        [debian_perl]="perl libperl-dev"
        [suse_perl]="perl perl-devel"
    )

    case $ID in
        centos|rhel|almalinux|rocky|ol)
            STEP_BEGIN "安装EL依赖"
            
            # ==== EL10专用处理 ====
            if [[ $RHEL_VERSION -eq 10 ]]; then
                STEP_BEGIN "处理EL10系统"
                $PKG_MANAGER update -y || STEP_WARNING "系统更新跳过"
                
                # 仅RHEL需要EPEL
                if [[ "$ID" == "rhel" ]]; then
                    STEP_BEGIN "安装EPEL源"
                    $PKG_MANAGER install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm || 
                    STEP_WARNING "EPEL安装跳过"
                fi
                
                # EL10的特殊依赖处理
                STEP_BEGIN "安装EL10专用依赖"
                $PKG_MANAGER install -y ${OS_SPECIFIC_DEPS[el10_special]} || 
                STEP_WARNING "部分EL10专有依赖安装失败"
            else
                # 原有RHEL 8/9处理逻辑
                $PKG_MANAGER install -y epel-release 2>/dev/null || STEP_WARNING "EPEL安装跳过"
                $PKG_MANAGER update -y || STEP_WARNING "系统更新跳过"
            fi
            
            # 统一安装开发工具链
            if [[ "$PKG_MANAGER" == "dnf" ]]; then
                $PKG_MANAGER group install -y "${OS_SPECIFIC_DEPS[rhel_group]}" || 
                STEP_WARNING "开发工具组安装部分失败"
            else
                $PKG_MANAGER groupinstall -y "${OS_SPECIFIC_DEPS[rhel_group]}" || 
                STEP_WARNING "开发工具组安装部分失败"
            fi
            
            # 基础依赖安装（兼容所有版本）
            $PKG_MANAGER install -y ${OS_SPECIFIC_DEPS[rhel_base]} ${OS_SPECIFIC_DEPS[rhel_tools]} ||
            STEP_FAIL "基础依赖安装失败"
            
            # 安装Perl相关依赖
            STEP_BEGIN "安装Perl开发环境"
            $PKG_MANAGER install -y ${OS_SPECIFIC_DEPS[perl_base]} || STEP_WARNING "Perl依赖安装部分失败"
            
            if [[ $RHEL_VERSION -eq 10 ]]; then
                STEP_SUCCESS "EL10依赖安装完成"
                STEP_INFO "此版本提供10年维护周期 (2024-2034)"
            else
                STEP_SUCCESS "RHEL依赖安装完成"
            fi
            ;;
            
        ubuntu|debian)
            STEP_BEGIN "安装Debian依赖"
            export DEBIAN_FRONTEND=noninteractive
            $PK极_MANAGER update -y || STEP_WARNING "包列表更新跳过"
            $PKG_MANAGER install -y ${OS_SPECIFIC_DEPS[debian_tools]} ${OS_SPECIFIC_DEPS[debian_base]} || STEP_FAIL "基础依赖安装失败"
            
            # 安装Perl相关依赖
            STEP_BEGIN "安装Perl开发环境"
            $PKG_MANAGER install -y ${OS_SPECIFIC_DEPS[debian_perl]} || STEP_WARNING "Perl依赖安装部分失败"
            
            STEP_SUCCESS "Debian依赖安装完成"
            ;;
            
        opensuse*|sles)
            STEP_BEGIN "安装SUSE依赖"
            $PKG_MANAGER refresh || STEP_WARNING "软件源刷新跳过"
            $PKG_MANAGER install -y ${OS_SPECIFIC_DEPS[suse_tools]} ${OS_SPECIFIC_DEPS[suse_base]} || STEP_FAIL "基础依赖安装失败"
            
            # 安装Perl相关依赖
            STEP_BEGIN "安装Perl开发环境"
            $PKG_MANAGER install -y ${OS_SPECIFIC_DEPS[suse_perl]} || STEP_WARNING "Perl依赖安装部分失败"
            
            STEP_SUCCESS "SUSE依赖安装完成"
            ;;
    esac
    
    STEP_BEGIN "验证编译工具"
    for cmd in gcc make flex bison; do
        if ! command -v $cmd >/dev/null 2>&1; then
            STEP_WARNING "工具缺失: $cmd (将尝试继续编译)"
        else
            echo "检测到 $cmd: $(command -v $cmd)"
        fi
    done
    STEP_SUCCESS "核心编译工具验证完成"
}

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

# 检查并安装缺失的Perl模块
install_perl_modules() {
    STEP_BEGIN "检测Perl环境"
    
    # 检查Perl解释器是否存在
    if ! command -v perl &>/dev/null; then
        STEP_FAIL "Perl解释器未安装，请检查依赖安装步骤"
    fi
    
    # 验证Perl版本
    PERL_VERSION=$(perl -e 'print $^V')
    STEP_SUCCESS "检测到Perl版本: $PERL_VERSION"
    
    # 设置CPAN为非交互模式
    STEP_BEGIN "配置CPAN非交互模式"
    (echo y; echo o conf prerequisites_policy follow; echo o conf commit) | cpan >/dev/null 2>&1 || true
    STEP_SUCCESS "CPAN配置完成"
    
    # 定义必需的核心Perl模块
    declare -a REQUIRED_MODULES=(
        "ExtUtils::Embed"     # PL/Perl必需
        "Test::More"          # 测试框架
        "IPC::Run"            # 进程控制
        "File::Spec"          # 文件路径处理
        "Data::Dumper"        # 数据结构调试
    )
    
    STEP_BEGIN "检查必需Perl模块"
    local missing_modules=()
    
    for module in "${REQUIRED_MODULES[@]}"; do
        if ! perl -M$module -e "1" >/dev/null 2>&1; then
            STEP_WARNING "模块缺失: $module"
            missing_modules+=("$module")
        fi
    done
    
    if [ ${#missing_modules[@]} -eq 0 ]; then
        STEP_SUCCESS "所有必需Perl模块已安装"
        return 0
    fi
    
    STEP_INFO "需要安装以下模块: ${missing_modules[*]}"
    
    # 安装缺失模块
    STEP_BEGIN "通过CPAN安装缺失模块"
    for module in "${missing_modules[@]}"; do
        STEP_INFO "正在安装: $module"
        if ! cpan -i "$module" >> "${LOG_DIR}/cpan_install.log" 2>&1; then
            STEP_WARNING "$module 安装失败，请查看 ${LOG_DIR}/cpan_install.log"
        else
            STEP_SUCCESS "$module 安装完成"
        fi
    done
    
    # 最终验证
    STEP_BEGIN "验证模块安装结果"
    local still_missing=()
    for module in "${missing_modules[@]}"; do
        if ! perl -M$module -e "1" >/dev/null 2>&1; then
            still_missing+=("$module")
        fi
    done
    
    if [ ${#still_missing[@]} -gt 0 ]; then
        STEP_WARNING "以下模块仍缺失: ${still_missing[*]}"
        STEP_INFO "建议手动安装: sudo cpan ${still_missing[*]}"
    else
        STEP_SUCCESS "所有必需Perl模块已成功安装"
    fi
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
        $git_clone_cmd || STEP_FAIL "代码克隆失败"
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
    
    # 增强的Perl模块处理
    install_perl_modules
    
    STEP_BEGIN "配置编译参数"
    CONFIGURE_OPTS="--prefix=$INSTALL_DIR --with-openssl"

detect_dependency() {
    local header_path="$1"
    local pkg_name="$2"
    local config_tool="$3"
    
    if [[ -f "$header_path" ]]; then
        return 0
    fi
    
    if command -v pkg-config &> /dev/null && pkg-config --exists "$pkg_name"; then
        return 0
    fi
    
    if [[ -n "$config_tool" ]] && command -v "$config_tool" &> /dev/null; then
        return 0
    fi
    
    return 1
}

if ! detect_dependency "/usr/include/unicode/utypes.h" "icu-uc" && \
   ! detect_dependency "/usr/include/icu.h" "icu-uc"; then
    CONFIGURE_OPTS+=" --without-icu"
    echo "警告：ICU库未找到，已禁用ICU支持"
fi

if ! detect_dependency "/usr/include/libxml2/libxml/parser.h" "libxml-2.0" "xml2-config"; then
    CONFIGURE_OPTS+=" --without-libxml"
    echo "警告：LibXML2未找到，已禁用XML支持"
fi

if ! detect_dependency "/usr/include/tcl.h" "tcl" "tclsh" && \
   ! command -v tclsh &> /dev/null; then
    CONFIGURE_OPTS+=" --without-tcl"
    echo "警告：TCL开发环境未找到，已禁用TCL扩展"
fi
   
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

main() {
    echo -e "\n\033[36m=========================================\033[0m"
    echo -e "\033{36m         IvorySQL 自动化安装脚本\033[0m"
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
