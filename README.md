English | [中文](README_CN.md)
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
TAG=IvorySQL_4.6
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
3. Enter the directory :
   ```bash
   cd IvorySQL-AutoInstaller
   ```
   add execute permission:
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
   TAG=IvorySQL_4.6
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

### 3.5 Installation Verification 
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







