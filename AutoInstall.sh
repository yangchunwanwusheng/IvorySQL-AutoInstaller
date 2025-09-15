#!/bin/bash
set -eo pipefail

# Non-interactive mode: set to 1 to skip all read -p confirmations
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OS_TYPE=""
OS_VERSION=""
XML_SUPPORT=0  

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

# ---- helpers added (service detection and wrappers) ----
has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_systemd() { has_cmd systemctl && [ -d /run/systemd/system ]; }

sc() { env PYTHONWARNINGS=ignore systemctl "$@"; }

svc_daemon_reload(){ if has_systemd; then sc daemon-reload; fi; }
svc_enable(){ if has_systemd; then sc enable "$1"; fi; }
svc_start(){
  if has_systemd; then
    sc start "$1"
  else
    su - "$SERVICE_USER" -c "$INSTALL_DIR/bin/pg_ctl start -D $DATA_DIR -s -w -t 60"
  fi
}
svc_stop(){
  if has_systemd; then
    sc stop "$1"
  else
    su - "$SERVICE_USER" -c "$INSTALL_DIR/bin/pg_ctl stop -D $DATA_DIR -s -m fast"
  fi
}
svc_is_active(){
  if has_systemd; then
    sc is-active --quiet "$1"
  else
    pgrep -f "$INSTALL_DIR/bin/postgres.*-D $DATA_DIR" >/dev/null 2>&1
  fi
}
svc_status_dump(){ if has_systemd; then sc status "$1" -l --no-pager; fi; }
svc_logs_tail(){
  if has_systemd && has_cmd journalctl; then
    journalctl -u "$1" -n 50 --no-pager
  else
    tail -n 100 "$LOG_DIR"/*.log 2>/dev/null || true
  fi
}

die() {
    local msg="$1"; shift || true
    echo -e "[31m✗ ${msg}[0m" >&2
    [[ $# -gt 0 ]] && echo -e "$*" >&2
    exit 1
}
handle_error() {
    local line=$1 command=$2
    STEP_FAIL  "Installation failed！: ${line} \n: ${command}"
    echo  "logPlease see: ${LOG_DIR}/error_${TIMESTAMP}.log"
    echo  "Please run the following commands to troubleshoot:"
    echo "1. systemctl status ivorysql.service"
    echo "2. journalctl -xe"
    echo "3. sudo -u ivorysql '${INSTALL_DIR}/bin/postgres -D ${DATA_DIR} -c logging_collector=on -c log_directory=${LOG_DIR}'"
    exit 1
}

trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

validate_config() {
    local key=$1 value=$2
    
    case $key in
        INSTALL_DIR|DATA_DIR|LOG_DIR)
            if [[ ! "$value" =~ ^/[^[:space:]]+$ ]]; then
                STEP_FAIL  "Configuration error: $key mustpath (current value: '$value')"
            fi
            
            if [[ -e "$value" ]]; then
                if [[ -f "$value" ]]; then
                    STEP_FAIL  "Configuration error: $key mustdirectorypath, Detectfile (current value: '$value')"
                fi
                
                if ! [[ -w "$value" ]]; then
                    if [[ -O "$value" ]]; then
                        STEP_FAIL  "Configuration error: $key pathnot writable (userpermission)"
                    else
                        STEP_FAIL  "Configuration error: $key pathnot writable (requires $USER permission)"
                    fi
                fi
            else
                local parent_dir=$(dirname "$value")
                mkdir -p "$parent_dir" || STEP_FAIL  "Createdirectory: $parent_dir"
                if [[ ! -w "$parent_dir" ]]; then
                    STEP_FAIL  "Configuration error: $key directorynot writable (path: '$parent_dir')"
                fi
            fi
            ;;
            
        SERVICE_USER|SERVICE_GROUP)
            local reserved_users="root bin daemon adm lp sync shutdown halt mail operator games ftp"
            if grep -qw "$value" <<< "$reserved_users"; then
                STEP_FAIL  "Configuration error: $key Usingsystem (current value: '$value')"
            fi
            
            if [[ ! "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$ ]]; then
                STEP_FAIL  "Configuration error: $key invalid name (current value: '$value')"
                echo  "Naming rules: , includes, , (_)(-), 1-32"
            fi
            
            if [[ $key == "SERVICE_USER" ]]; then
                if ! getent passwd "$value" &>/dev/null; then
                    STEP_SUCCESS  "Createuser: $value"
                fi
            else
                if ! getent group "$value" &>/dev/null; then
                    STEP_SUCCESS  "Creategroup: $value"
                fi
            fi
            ;;
            
        REPO_URL)
            if [[ ! "$value" =~ ^https?://[a-zA-Z0-9./_-]+$ ]]; then
                STEP_FAIL  "Configuration error: REPO_URL invalid format (current value: '$value')"
            fi
            
            if [[ ! "$value" =~ github\.com/IvorySQL/IvorySQL ]]; then
                STEP_WARNING  "Warning: Usingrepository ($value)"
                if [[ $NON_INTERACTIVE -eq 1 ]]; then
                STEP_WARNING  "Detectnon-official repository(auto-accepted, NON_INTERACTIVE=1)"
            else
                read -p "Confirm usingnon-official repository? (y/N)" -n 1 -r
                echo
                [[ ! $REPLY =~ ^[Yy]$ ]] && STEP_FAIL  "Installaborted: usernon-official repository"
            fi
            fi
            ;;
            
        BRANCH|TAG)
            if [[ -n "$value" ]]; then
                if [[ "$value" =~ [\$\&\;\|\>\<\!\\\'\"] ]]; then
                    STEP_FAIL  "Configuration error: $key contains unsafe characters (current value: '$value')"
                fi
                
                if [[ ${#value} -gt 100 ]]; then
                    STEP_WARNING  "Warning: $key length exceeds100 (current value: '$value')"
                    if [[ $NON_INTERACTIVE -eq 1 ]]; then
                    STEP_WARNING  "Detectoverlong identifier(auto-accepted, NON_INTERACTIVE=1)"
                else
                    read -p "Confirm usingoverlong identifier? (y/N)" -n 1 -r
                    echo
                    [[ ! $REPLY =~ ^[Yy]$ ]] && STEP_FAIL  "Installaborted: useroverlong identifier"
                fi
                fi
            fi
            ;;
    esac
}

load_config() {
    CURRENT_STAGE "ConfigurationLoad"
    
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

CONFIG_FILE="${SCRIPT_DIR}/ivorysql.conf"

STEP_BEGIN  "CheckConfiguration file"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        STEP_FAIL  "Configuration file $CONFIG_FILE , Please ensure 'ivorysql.conf' directory"
    fi
STEP_SUCCESS  "Configuration file"

STEP_BEGIN  "LoadConfiguration file"
if grep -Evq '^\s*([A-Z_][A-Z0-9_]*\s*=\s*.*|#|$)' "$CONFIG_FILE"; then
    STEP_FAIL  "Configuration fileincludessupport( KEY=VALUE, , )"
fi
source "$CONFIG_FILE" || STEP_FAIL  "LoadConfiguration file $CONFIG_FILE, Checkfileformat"
STEP_SUCCESS  "Configuration fileLoadSuccess"
    
    STEP_BEGIN  "ValidateConfiguration"
    declare -a required_vars=("INSTALL_DIR" "DATA_DIR" "SERVICE_USER" "SERVICE_GROUP" "REPO_URL" "LOG_DIR")
    for var in "${required_vars[@]}"; do
        [[ -z "${!var}" ]] && STEP_FAIL  "Configuration missing: $var"
    done
    STEP_SUCCESS  "ConfigurationValidate"
    
    if [[ -z "$TAG" && -z "$BRANCH" ]]; then
        STEP_FAIL  "must TAG BRANCH"
    elif [[ -n "$TAG" && -n "$BRANCH" ]]; then
        STEP_WARNING  "TAG BRANCH, will prefer TAG($TAG)"
    fi
    
    STEP_BEGIN  "CheckConfiguration"
    while IFS='=' read -r key value; do
        [[ $key =~ ^[[:space:]]*# || -z $key ]] && continue
        key=$(echo $key | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        validate_config "$key" "$value"
    done < "$CONFIG_FILE"
    STEP_SUCCESS  "ConfigurationValidate"
}

init_logging() {
    CURRENT_STAGE "log"
    
    STEP_BEGIN  "Createlog directory"
    mkdir -p "$LOG_DIR" || STEP_FAIL  "Createlog directory $LOG_DIR"
    
    if id -u "$SERVICE_USER" &>/dev/null && getent group "$SERVICE_GROUP" &>/dev/null; then
        chown "$SERVICE_USER:$SERVICE_GROUP" "$LOG_DIR" || STEP_WARNING  "log directorypermissionFailed, Install"
        STEP_SUCCESS  "log directoryCreatepermission"
    else
        STEP_WARNING  "user/group, permission"
        STEP_SUCCESS  "log directoryCreate"
    fi
    
    STEP_BEGIN  "redirectionoutput streams"
    exec > >(tee -a "${LOG_DIR}/install_${TIMESTAMP}.log")
    exec 2> >(tee -a "${LOG_DIR}/error_${TIMESTAMP}.log" >&2)
    STEP_SUCCESS  "logredirection"
}

check_root() {
    CURRENT_STAGE "permissionCheck"
    
    STEP_BEGIN  "Validateuserpermission"
    [[ "$(id -u)" -ne 0 ]] && { 
        STEP_FAIL  "mustUsingrootpermission"
        echo -e  "Please run: \033[33msudo"$0" "$@"\033[0m" >&2
        exit 1
    }
    STEP_SUCCESS  "rootpermissionValidate"
}

detect_environment() {
    CURRENT_STAGE "systemDetect"
    
    get_major_version() {
        grep -Eo 'VERSION_ID="?[0-9.]+' /etc/os-release | 
        cut -d= -f2 | tr -d '"' | cut -d. -f1
    }

    STEP_BEGIN  "OS"
    [[ ! -f /etc/os-release ]] && STEP_FAIL  "OS"
    source /etc/os-release
    
    OS_TYPE="$ID"
    OS_VERSION="$VERSION_ID"
    
    PKG_MANAGER=""
    STEP_SUCCESS  "DetectOS: $PRETTY_NAME"
    
    # Special handling for Oracle Linux
    if [[ -f /etc/oracle-release ]]; then
        OS_TYPE="oracle"
        ORACLE_VERSION=$(grep -oE '([0-9]+)\.?([0-9]+)?' /etc/oracle-release | head -1)
        STEP_SUCCESS  "DetectOracle Linux $ORACLE_VERSION"
    fi
    
    case "$OS_TYPE" in
        centos|rhel|almalinux|rocky|fedora|oracle)
            RHEL_VERSION=$(get_major_version)
            [[ -z $RHEL_VERSION ]] && STEP_FAIL  "Fetchversion"
            
            if [[ $RHEL_VERSION -eq 7 ]]; then
                STEP_FAIL  "CentOS/RHEL 7Please runYUMInstall"
            elif [[ $RHEL_VERSION =~ ^(8|9|10)$ ]]; then
                if command -v dnf &>/dev/null; then
                    PKG_MANAGER="dnf"
                    STEP_SUCCESS  "Usingpackage manager: dnf"
                else
                    PKG_MANAGER="yum"
                    STEP_WARNING  "dnf, Usingyum"
                fi
            else
                STEP_FAIL  "supportversion: $RHEL_VERSION"
            fi
            ;;
            
        ubuntu|debian)
            OS_VERSION=$(grep -Po '(?<=VERSION_ID=")[0-9.]+' /etc/os-release)
            MAJOR_VERSION=${OS_VERSION%%.*}
            
            case "$OS_TYPE" in
                ubuntu)
                    [[ $MAJOR_VERSION =~ ^(18|20|22|24)$ ]] || 
                    STEP_FAIL  "supportUbuntuversion: $OS_VERSION" ;;
                debian)
                    [[ $MAJOR_VERSION =~ ^(10|11|12)$ ]] || 
                    STEP_FAIL  "supportDebianversion: $OS_VERSION" ;;
            esac
            
            PKG_MANAGER="apt-get"
            STEP_SUCCESS  "Usingpackage manager: apt-get"
            ;;
            
        opensuse*|sles)
            SLE_VERSION=$(grep -Po '(?<=VERSION_ID=")[0-9.]+' /etc/os-release)
            
            if [[ "$ID" == "opensuse-leap" ]]; then
                [[ $SLE_VERSION =~ ^15 ]] || STEP_FAIL  "supportopenSUSE Leapversion"
            elif [[ "$ID" == "sles" ]]; then
                [[ $SLE_VERSION =~ ^(12\.5|15) ]] || STEP_FAIL  "supportSLESversion"
            else
                STEP_FAIL  "UnknownSUSE"
            fi
            
            PKG_MANAGER="zypper"
            STEP_SUCCESS  "Usingpackage manager: zypper"
            ;;
            
        arch)
            PKG_MANAGER="pacman"
            STEP_SUCCESS  "Arch Linux support" ;;
            
        *)
            if [[ -f /etc/redhat-release ]]; then
                STEP_FAIL  "UnknownRHEL"
            elif [[ -f /etc/debian_version ]]; then
                STEP_FAIL  "UnknownDebian"
            else
                STEP_FAIL  "Linux"
            fi
            ;;
    esac
}

install_dependencies() {
    CURRENT_STAGE "Installsystemdependencies"
    
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

    STEP_BEGIN  ""
    case "$OS_TYPE" in
        centos|rhel|almalinux|rocky|fedora|oracle)
            $PKG_MANAGER install -y epel-release 2>/dev/null || true
            
            # EL10-specific handling - enhanced XML library installation
            if [[ $RHEL_VERSION -eq 10 ]]; then
                STEP_BEGIN  "EL10enableCRBrepositoryInstallXMLdevelopment library"
                if [[ "$OS_TYPE" == "rocky" ]]; then
                    # Ensure CRB repository is enabled
                    if ! $PKG_MANAGER config-manager --set-enabled crb 2>/dev/null; then
                        STEP_WARNING  "enableCRBrepository, tryUsingDevelrepository"
                        $PKG_MANAGER config-manager --set-enabled devel 2>/dev/null || true
                    fi
                    
                    # Explicitly attempt to install libxml2-devel
                    if $PKG_MANAGER install -y libxml2-devel; then
                        XML_SUPPORT=1
                        STEP_SUCCESS  "SuccessInstall libxml2-devel, enableXMLsupport"
                    else
                        # Try alternative package names
                        STEP_BEGIN  "tryXML"
                        if $PKG_MANAGER install -y libxml2-dev; then
                            XML_SUPPORT=1
                            STEP_SUCCESS  "SuccessInstall libxml2-dev, enableXMLsupport"
                        else
                            XML_SUPPORT=0
                            STEP_WARNING  "InstallXMLdevelopment library, XMLsupport"
                        fi
                    fi
                elif [[ "$OS_TYPE" == "oracle" ]]; then
                    # Oracle Linux 10 specific repo handling
                    STEP_BEGIN  "enableOracle Linux 10repository"
                    if $PKG_MANAGER repolist | grep -q "ol10_developer"; then
                        $PKG_MANAGER config-manager --enable ol10_developer || true
                    elif $PKG_MANAGER repolist | grep -q "ol10_addons"; then
                        $PKG_MANAGER config-manager --enable ol10_addons || true
                    fi
                    STEP_SUCCESS  "repositoryConfiguration"
                else
                    $PKG_MANAGER config-manager --set-enabled codeready-builder || true
                fi
                STEP_SUCCESS  "repositoryConfiguration"
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
            pacman -Sy --noconfirm
            ;;
    esac
    STEP_SUCCESS  ""

# Ensure pkg-config exists (needed by ICU detection)
STEP_BEGIN  "Installpkg-config"
case "$OS_TYPE" in
    centos|rhel|almalinux|rocky|fedora|oracle)
        $PKG_MANAGER install -y pkgconf-pkg-config || $PKG_MANAGER install -y pkgconfig || true
        ;;
    ubuntu|debian)
        $PKG_MANAGER install -y pkg-config || true
        ;;
    opensuse*|sles)
        $PKG_MANAGER install -y pkgconf-pkg-config || $PKG_MANAGER install -y pkg-config || true
        ;;
    arch)
        pacman -S --noconfirm pkgconf || true
        ;;
esac
if command -v pkg-config >/dev/null 2>&1; then
    STEP_SUCCESS  "pkg-config: $(pkg-config --version)"
else
    STEP_WARNING  "pkg-config not found (will disable ICU and other features that require it)"
fi

    STEP_BEGIN  "Installdependencies"
    case "$OS_TYPE" in
        centos|rhel|almalinux|rocky|fedora|oracle)
            # Oracle Linux specific settings
            if [[ "$OS_TYPE" == "oracle" ]]; then
                STEP_BEGIN  "InstallOracle Linuxdependencies"
                $PKG_MANAGER install -y oraclelinux-developer-release-el${RHEL_VERSION} 2>/dev/null || true
                $PKG_MANAGER group install -y "Development Tools" 2>/dev/null || true
                STEP_SUCCESS  "Oracledependencies"
            fi
            
            # General EL dependency installation
            if [[ "$PKG_MANAGER" == "dnf" ]]; then
                $PKG_MANAGER group install -y "${OS_SPECIFIC_DEPS[rhel_group]}" || true
            else
                $PKG_MANAGER groupinstall -y "${OS_SPECIFIC_DEPS[rhel_group]}" || true
            fi
            
            # Force install readline-devel
            STEP_BEGIN  "Installreadline"
            $PKG_MANAGER install -y readline-devel || STEP_FAIL  "readline-develInstallation failed, mustInstallreadline"
            STEP_SUCCESS  "readlineInstallation succeeded"
            
            # Special handling: ensure XML development library is installed (for non-EL10 or EL10 cases not covered above)
            if [[ $XML_SUPPORT -eq 0 && $RHEL_VERSION -ne 10 ]]; then
                STEP_BEGIN  "InstallXMLdevelopment library"
                if $PKG_MANAGER install -y ${OS_SPECIFIC_DEPS[libxml_dep]}; then
                    XML_SUPPORT=1
                    STEP_SUCCESS  "XMLdevelopment libraryInstallation succeeded"
                else
                    STEP_WARNING  "XMLdevelopment libraryInstallation failed, XMLsupport"
                fi
            fi
            
            $PKG_MANAGER install -y \
                ${OS_SPECIFIC_DEPS[rhel_base]} \
                ${OS_SPECIFIC_DEPS[perl_deps]} \
                tcl-devel libicu-devel || true
            ;;
        ubuntu|debian)
            # Force install libreadline-dev
            STEP_BEGIN  "Installlibreadline-dev"
            $PKG_MANAGER install -y libreadline-dev || STEP_FAIL  "libreadline-devInstallation failed, mustInstallreadline"
            STEP_SUCCESS  "readlineInstallation succeeded"
            
            $PKG_MANAGER install -y \
                ${OS_SPECIFIC_DEPS[debian_tools]} \
                ${OS_SPECIFIC_DEPS[debian_base]} \
                ${OS_SPECIFIC_DEPS[debian_libxml]} \
                libperl-dev perl-modules || true
            ;;
        opensuse*|sles)
            # Force install readline-devel
            STEP_BEGIN  "Installreadline-devel"
            $PKG_MANAGER install -y readline-devel || STEP_FAIL  "readline-develInstallation failed, mustInstallreadline"
            STEP_SUCCESS  "readlineInstallation succeeded"
            
            $PKG_MANAGER install -y \
                ${OS_SPECIFIC_DEPS[suse_tools]} \
                ${OS_SPECIFIC_DEPS[suse_base]} \
                ${OS_SPECIFIC_DEPS[suse_libxml]} \
                perl-devel perl-ExtUtils-Embed || true
            ;;
        arch)
            # Force install readline
            STEP_BEGIN  "Installreadline"
            pacman -S --noconfirm readline || STEP_FAIL  "readlineInstallation failed, mustInstallreadline"
            STEP_SUCCESS  "readlineInstallation succeeded"
            
            pacman -S --noconfirm \
                ${OS_SPECIFIC_DEPS[arch_base]} \
                ${OS_SPECIFIC_DEPS[arch_tools]} \
                ${OS_SPECIFIC_DEPS[arch_libxml]} || true
            ;;
    esac
    STEP_SUCCESS  "dependenciesInstallation completed"

    # Install required Perl modules
    STEP_BEGIN  "Install Perl modules"
    case "$OS_TYPE" in
        centos|rhel|almalinux|rocky|fedora|oracle)
            # Install Perl core modules and dev tools
            $PKG_MANAGER install -y perl-core perl-devel || true
            
            # Try installing IPC-Run
            if ! $PKG_MANAGER install -y perl-IPC-Run 2>/dev/null; then
                STEP_WARNING  "perl-IPC-Run , try CPAN Install"
                # Use CPAN to install missing modules
                PERL_MM_USE_DEFAULT=1 cpan -i IPC::Run FindBin || {
                    STEP_WARNING  "CPAN Installation failed, try"
                    # If CPAN is unavailable, try cpanm
                    curl -L https://cpanmin.us | perl - App::cpanminus || true
                    cpanm IPC::Run FindBin || STEP_WARNING  "Perl modulesInstall"
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
    STEP_SUCCESS  "Perl modulesInstallation completed"

    STEP_BEGIN  "ValidateBuild"
    for cmd in gcc make flex bison; do
        if ! command -v $cmd >/dev/null 2>&1; then
            STEP_WARNING  "missing: $cmd (will tryBuild)"
        else
            echo  "Detect $cmd: $(command -v $cmd)"
        fi
    done
    
    if ! command -v perl >/dev/null 2>&1; then
        STEP_WARNING  "Warning: Perl interpreternot found, Build"
    else
        echo  "Detect Perl: $(command -v perl)"
        echo  "Perlversion: $(perl --version | head -n 2 | tail -n 1)"
    fi
    
    # Enhanced XML support detection
    STEP_BEGIN  "DetectXMLsupport"
    if [[ -f /usr/include/libxml2/libxml/parser.h || -f /usr/include/libxml/parser.h ]]; then
        XML_SUPPORT=1
        STEP_SUCCESS  "XMLdevelopment libraryfound, will enableXMLsupport"
    else
        XML_SUPPORT=0
        STEP_WARNING  "XMLdevelopment librarynot found, InstallXML"
    fi
    
    # ensureLibXML2development library - Rocky Linux 10
    if [[ $XML_SUPPORT -eq 0 ]]; then
        STEP_BEGIN  "tryInstallLibXML2"
        case "$OS_TYPE" in
            centos|rhel|almalinux|rocky|oracle)
                # Rocky Linux 10, UsingInstall
                if [[ "$OS_TYPE" == "rocky" && $RHEL_VERSION -eq 10 ]]; then
                    STEP_BEGIN  "Rocky Linux 10trymultiple methodsInstalllibxml2-devel"
                    # 1: tryenableCRBrepositoryInstall
                    $PKG_MANAGER config-manager --set-enabled crb 2>/dev/null || true
                    if $PKG_MANAGER install -y libxml2-devel; then
                        XML_SUPPORT=1
                        STEP_SUCCESS  "CRBrepositorySuccessInstalllibxml2-devel"
                    else
                        # 2: tryenableDevelrepository
                        $PKG_MANAGER config-manager --set-enabled devel 2>/dev/null || true
                        if $PKG_MANAGER install -y libxml2-devel; then
                            XML_SUPPORT=1
                            STEP_SUCCESS  "DevelrepositorySuccessInstalllibxml2-devel"
                        else
                            # 3: tryUsingdnf--allowerasing
                            if $PKG_MANAGER install -y --allowerasing libxml2-devel; then
                                XML_SUPPORT=1
                                STEP_SUCCESS  "Using--allowerasingSuccessInstalllibxml2-devel"
                            else
                                XML_SUPPORT=0
                                STEP_WARNING  "Installlibxml2-develFailed"
                            fi
                        fi
                    fi
                else
                    # system, Using
                    $PKG_MANAGER install -y libxml2-devel || true
                fi
                ;;
            ubuntu|debian)
                $PKG_MANAGER install -y libxml2-dev || true
                ;;
            opensuse*|sles)
                $PKG_MANAGER install -y libxml2-devel || true
                ;;
            arch)
                pacman -S --noconfirm libxml2 || true
                ;;
        esac
        
        # Check
        if [[ -f /usr/include/libxml2/libxml/parser.h || -f /usr/include/libxml/parser.h ]]; then
            XML_SUPPORT=1
            STEP_SUCCESS  "XMLdevelopment libraryInstallation succeeded, enableXMLsupport"
        else
            XML_SUPPORT=0
            STEP_WARNING  "XMLdevelopment libraryInstallation failed, will disableXMLsupport"
        fi
    fi
    STEP_SUCCESS  "BuildValidate"
}

setup_user() {
    CURRENT_STAGE "Configurationsystemuser"
    
    STEP_BEGIN  "Createusergroup"
    if ! getent group "$SERVICE_GROUP" &>/dev/null; then
        groupadd "$SERVICE_GROUP" || STEP_FAIL  "usergroupCreateFailed"
        STEP_SUCCESS  "usergroupCreate: $SERVICE_GROUP"
    else
        STEP_SUCCESS  "usergroup: $SERVICE_GROUP"
    fi

    STEP_BEGIN  "Createuser"
    if ! id -u "$SERVICE_USER" &>/dev/null; then
        useradd -r -g "$SERVICE_GROUP" -s "/bin/bash" -m -d "/home/$SERVICE_USER" "$SERVICE_USER" || STEP_FAIL  "userCreateFailed"
        STEP_SUCCESS  "userCreate: $SERVICE_USER"
    else
        STEP_SUCCESS  "user: $SERVICE_USER"
    fi
}

compile_install() {
    CURRENT_STAGE "BuildInstall"
    
    local repo_dir
    repo_dir="$(basename "$REPO_URL" .git)"
    STEP_BEGIN  "Fetch"
    if [[ ! -d "$repo_dir" ]]; then
        git_clone_cmd="git clone"
        
        if [[ -n "$TAG" ]]; then
            STEP_BEGIN  "UsingtagFetch ($TAG)"
            git_clone_cmd+=" -b $TAG"
        elif [[ -n "$BRANCH" ]]; then
            STEP_BEGIN  "UsingbranchFetch ($BRANCH)"
            git_clone_cmd+=" -b $BRANCH"
        fi
        
        git_clone_cmd+=" --progress $REPO_URL"
        
        echo  ": $git_clone_cmd"
        # retry
        for i in {1..3}; do
            if $git_clone_cmd; then
                break
            fi
            if [[ $i -eq 3 ]]; then
                STEP_FAIL  "Failed, Checkrepository"
            fi
            STEP_WARNING  "try $i/3 Failed, 10retry."
            sleep 10
        done
        STEP_SUCCESS  "repository"
    else
        STEP_SUCCESS  "repository: $repo_dir"
    fi
    cd "$repo_dir" || STEP_FAIL  "directory: $repo_dir"
    
    if [[ -n "$TAG" ]]; then
        STEP_BEGIN  "Validatetag ($TAG)"
        git checkout "tags/$TAG" || STEP_FAIL  "tagSwitchFailed: $TAG"
        COMMIT_ID=$(git rev-parse --short HEAD)
        STEP_SUCCESS  "tag $TAG (commit: $COMMIT_ID)"
    else
        STEP_BEGIN  "Switchbranch ($BRANCH)"
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
            git reset --hard || STEP_WARNING  "branchFailed(continue)"
            git clean -fd || STEP_WARNING  "Failed(continue)"
            git checkout "$BRANCH" --progress || STEP_FAIL  "branchSwitchFailed: $BRANCH"
            git pull origin "$BRANCH" --progress || STEP_WARNING  "Failed(continue)"
            STEP_SUCCESS  "Switchbranch: $BRANCH"
        else
            STEP_SUCCESS  "branch: $BRANCH"
        fi
        COMMIT_ID=$(git rev-parse --short HEAD)
        STEP_SUCCESS  "version: $COMMIT_ID"
    fi
    
    # Validate Perl
    STEP_BEGIN  "Validate Perl"
    REQUIRED_PERL_MODULES=("FindBin" "IPC::Run")
    MISSING_MODULES=()

    for module in "${REQUIRED_PERL_MODULES[@]}"; do
        if ! perl -M"$module" -e 1 2>/dev/null; then
            MISSING_MODULES+=("$module")
        fi
    done

    if [ ${#MISSING_MODULES[@]} -ne 0 ]; then
        STEP_WARNING  "Perl modules: ${MISSING_MODULES[*]}"
        STEP_BEGIN  "tryInstallmissing Perl modules"
        for module in "${MISSING_MODULES[@]}"; do
            if command -v cpanm >/dev/null 2>&1; then
                cpanm "$module" || STEP_WARNING  "Install $module"
            else
                cpan "$module" || STEP_WARNING  "Install $module"
            fi
        done
        STEP_SUCCESS  "Perl modulesInstalltry"
    fi

    # Check
    for module in "${REQUIRED_PERL_MODULES[@]}"; do
        if ! perl -M"$module" -e 1 2>/dev/null; then
            STEP_FAIL  "Perl modules $module missing, BuildFailed"
        fi
    done
    STEP_SUCCESS  "Perl Validate"
    
    STEP_BEGIN  "ConfigurationBuild"
    # Configuration - enablereadline(ensureInstall)
    CONFIGURE_OPTS="--prefix=$INSTALL_DIR --with-openssl --with-readline"
    STEP_SUCCESS  "enablereadlinesupport"

# Detect ICU via pkg-config (robust across distros)
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists icu-uc icu-i18n; then
    CONFIGURE_OPTS+=" --with-icu"
    STEP_SUCCESS  "ICU (pkg-config) detected, enablesupport"
else
    CONFIGURE_OPTS+=" --without-icu"
    if ! command -v pkg-config >/dev/null 2>&1; then
        STEP_WARNING  "pkg-config not found, disabled ICUsupport"
    else
        STEP_WARNING  "ICU .pc files not found, disabled ICUsupport"
    fi
fi

# XMLsupportConfiguration

    if [[ $XML_SUPPORT -eq 1 ]]; then
        CONFIGURE_OPTS+=" --with-libxml"
        STEP_SUCCESS  "XML, enablesupport"
    else
        CONFIGURE_OPTS+=" --without-libxml"
        STEP_WARNING  "XMLdevelopment librarynot found, disabledXMLsupport"
    fi
    
    # DetectTCL
    tcl_paths=("/usr/include/tcl.h" "/usr/include/tcl8.6/tcl.h")
    if [[ -f "${tcl_paths[0]}" || -f "${tcl_paths[1]}" ]]; then
        CONFIGURE_OPTS+=" --with-tcl"
        STEP_SUCCESS  "TCL development environment, enablesupport"
    else
        CONFIGURE_OPTS+=" --without-tcl"
        STEP_WARNING  "TCL development environmentnot found, disabledTCLextension"
    fi
    
    # DetectPerl
    perl_paths=("/usr/bin/perl" "/usr/local/bin/perl")
    if command -v perl >/dev/null; then
        perl_header=$(find /usr -name perl.h 2>/dev/null | head -n1)
        if [[ -n "$perl_header" ]]; then
            CONFIGURE_OPTS+=" --with-perl"
            STEP_SUCCESS  "Perl development environment, enablesupport"
        else
            CONFIGURE_OPTS+=" --without-perl"
            STEP_WARNING  "Perlfilemissing (perl.hnot found), support"
        fi
    else
        STEP_WARNING  "DetectPerl interpreter, Perlsupport"
        CONFIGURE_OPTS+=" --without-perl"
    fi
    
    echo  "Configuration: $CONFIGURE_OPTS"
    ./configure $CONFIGURE_OPTS || {
        STEP_FAIL  "ConfigurationFailed"
        echo  "Configurationlog:"
        tail -20 config.log
        exit 1
    }
    STEP_SUCCESS  "Configuration"
    
    STEP_BEGIN  "Build (Using$(nproc)threads)"
    make -j$(nproc) || STEP_FAIL  "BuildFailed"
    STEP_SUCCESS  "Build"
    
    STEP_BEGIN  "Installfile"
    make install || STEP_FAIL  "Installation failed"
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR" || STEP_FAIL  "InstalldirectorypermissionFailed"
    STEP_SUCCESS  "SuccessInstall: $INSTALL_DIR"
}

post_install() {
    CURRENT_STAGE "InstallConfiguration"
    
    STEP_BEGIN  "Preparedata directory"
    mkdir -p "$DATA_DIR" || STEP_FAIL  "Createdata directory $DATA_DIR"
    
    if [ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
        STEP_BEGIN  "Cleardata directory"
        svc_stop ivorysql 2>/dev/null || true
        rm -rf "${DATA_DIR:?}"/* "${DATA_DIR:?}"/.[^.]* "${DATA_DIR:?}"/..?* 2>/dev/null || true
        STEP_SUCCESS  "data directoryClear"
    else
        STEP_SUCCESS  "data directory(Using)"
    fi
    
    chown "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR"
    chmod 750 "$DATA_DIR"
    STEP_SUCCESS  "data directorypermission"

    STEP_BEGIN  "Configurationenvironment variables"
    user_home=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
    cat > "$user_home/.bash_profile" <<EOF
PATH="$INSTALL_DIR/bin:\$PATH"
export PATH
PGDATA="$DATA_DIR"
export PGDATA
EOF
    chown "$SERVICE_USER:$SERVICE_GROUP" "$user_home/.bash_profile"
    chmod 600 "$user_home/.bash_profile"
    
    su - "$SERVICE_USER" -c "source ~/.bash_profile" || STEP_WARNING  "environment variablesFailed(continue)"
    STEP_SUCCESS  "environment variablesset"

    STEP_BEGIN  ""
    INIT_LOG="${LOG_DIR}/initdb_${TIMESTAMP}.log"
    INIT_CMD="source ~/.bash_profile && initdb -D $DATA_DIR --no-locale --debug"
    
    if [[ $XML_SUPPORT -eq 0 ]]; then
        INIT_CMD+=" --no-ivorysql-ora"
        STEP_WARNING  "XMLsupportmissing, ivorysql_oraextension"
    fi
    
    if ! su - "$SERVICE_USER" -c "$INIT_CMD" > "$INIT_LOG" 2>&1; then
        STEP_FAIL  "Failed"
        echo  "======= log ======="
        tail -n 50 "$INIT_LOG"
        echo "=========================="
        echo  ": sudo -u $SERVICE_USER bash -c 'source ~/.bash_profile && initdb -D $DATA_DIR --debug'"
        exit 1
    fi
    
    if grep -q "FATAL" "$INIT_LOG"; then
        STEP_FAIL  "Detect"
        echo  "======= ======="
        grep -A 10 "FATAL" "$INIT_LOG"
        exit 1
    fi
    
    STEP_SUCCESS  ""

    STEP_BEGIN  "ConfigurationsystemService"
    if has_systemd; then
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
TimeoutSec=60
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

        svc_daemon_reload
        svc_enable ivorysql
        STEP_SUCCESS  "ServiceConfiguration"
    else
        STEP_WARNING  "Systemd not detected, skip creating service unit"
        cat > "$INSTALL_DIR/ivorysql-ctl" <<EOF
#!/bin/bash
PGDATA="$DATA_DIR"
case "$1" in
  start) "$INSTALL_DIR/bin/pg_ctl" start -D "\$PGDATA" -s -w -t 60 ;;
  stop)  "$INSTALL_DIR/bin/pg_ctl" stop  -D "\$PGDATA" -s -m fast ;;
  reload) "$INSTALL_DIR/bin/pg_ctl" reload -D "\$PGDATA" ;;
  *) echo "Usage: \$0 {start|stop|reload}" ; exit 1 ;;
esac
EOF
        chmod +x "$INSTALL_DIR/ivorysql-ctl"
        STEP_SUCCESS  "Helper script created: $INSTALL_DIR/ivorysql-ctl"
    fi
}


verify_installation() {
    CURRENT_STAGE "InstallValidate"
    
    STEP_BEGIN  "StartService"
    svc_start ivorysql || {
        STEP_FAIL  "ServiceStartFailed"
        echo  "======= Service ======="
        svc_status_dump ivorysql
        echo  "======= log ======="
        svc_logs_tail ivorysql
        exit 1
    }
    STEP_SUCCESS  "ServiceStartSuccess"

    STEP_BEGIN  "Service"
    for i in {1..15}; do
        if svc_is_active ivorysql; then
            STEP_SUCCESS  "ServiceRunning"
            break
        fi
        [[ $i -eq 15 ]] && {
            STEP_FAIL  "ServiceStarttimed out"
            svc_logs_tail ivorysql >&2
            exit 1
        }
        sleep 1
    done
    
    # Validateextension
    STEP_BEGIN  "Validateextension"
    if su - "$SERVICE_USER" -c "$INSTALL_DIR/bin/psql -d postgres -c \"SELECT * FROM pg_available_extensions WHERE name = 'ivorysql_ora'\"" | grep -q ivorysql_ora; then
        STEP_SUCCESS  "ivorysql_oraextensionSuccessLoad"
    else
        if [[ $XML_SUPPORT -eq 0 ]]; then
            STEP_WARNING  "ivorysql_oraextensionLoad(XMLsupportmissing)"
        else
            STEP_WARNING  "ivorysql_oraextensionLoad, Checklog"
        fi
    fi
    
    # Success
    show_success_message
}

show_success_message() {
    echo -e "\n\033[32m================ Installation succeeded ================\033[0m"

    local SERVICE_STATUS SERVICE_HELP LOG_FOLLOW
    if has_systemd; then
        if env PYTHONWARNINGS=ignore systemctl is-active --quiet ivorysql; then
            SERVICE_STATUS="$(env PYTHONWARNINGS=ignore systemctl is-active ivorysql 2>/dev/null || echo "unknown")"
        else
            SERVICE_STATUS="inactive"
        fi
        SERVICE_HELP='systemctl [start|stop|status] ivorysql'
        LOG_FOLLOW='journalctl -u ivorysql -f'
    else
        SERVICE_STATUS="(systemd not present; managed via pg_ctl helper)"
        SERVICE_HELP="$INSTALL_DIR/ivorysql-ctl {start|stop|reload}"
        LOG_FOLLOW="tail -f $LOG_DIR/*.log"
    fi
    # ----------------------------------------------------------------------

    cat <<EOF
Install directory: $INSTALL_DIR
Data directory: $DATA_DIR
Log directory: $LOG_DIR
Service: $SERVICE_STATUS
Version: $(${INSTALL_DIR}/bin/postgres --version)

Useful commands:
  $SERVICE_HELP
  $LOG_FOLLOW
  sudo -u $SERVICE_USER '${INSTALL_DIR}/bin/psql'

Install time: $(date)
Elapsed: ${SECONDS}s
Build: ${TAG:-$BRANCH}   Commit: ${COMMIT_ID:-N/A}
OS: $OS_TYPE $OS_VERSION
EOF

    [[ $XML_SUPPORT -eq 0 ]] && echo -e "\033[33mNote: XML support not enabled.\033[0m"
}


main() {
    echo -e "\n\033[36m=========================================\033[0m"
    echo -e  "\033[36m IvorySQL Install\033[0m"
    echo -e "\033[36m=========================================\033[0m"
    echo  "Start: $(date)"
    echo  "Install: $TIMESTAMP"
    echo  "Note: includesEL10systemsupport"
    
    SECONDS=0
    check_root          # 1. Checkrootpermission
    load_config         # 2. LoadConfiguration
    detect_environment  # 3. Detect
    setup_user          # 4. Createusergroup
    init_logging        # 5. log
    install_dependencies # 6. Installdependencies
    compile_install     # 7. BuildInstall
    post_install        # 8. InstallConfiguration
    verify_installation # 9. ValidateInstall
}

main "$@"
