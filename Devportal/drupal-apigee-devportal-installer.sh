#!/usr/bin/env bash
# install.sh — Apigee DevPortal Kickstart (Drupal 10) on RHEL/CentOS 9 with MariaDB 11 + Nginx + PHP 8.2
set -euo pipefail
trap 'echo "❌ Error at line $LINENO"; exit 1' ERR

# ── Tunables (env overrides allowed) ─────────────────────────────────────────
OS_NAME="${OS_NAME:-Red Hat 9}"

# Node role: web | db | all
# ROLE="${ROLE:-all}"

# --- Interactive config 
# Default: interactive ON. Set INTERACTIVE=false (or interactive=false) to skip prompts.
INTERACTIVE="${INTERACTIVE:-${interactive:-true}}"

# Identities
RUNUSER="${RUNUSER:-devportal}"     # owns the codebase, runs composer/drush
WEBGROUP="${WEBGROUP:-nginx}"       # webserver group for file access
WEBUSER="${WEBUSER:-nginx}"         # php-fpm/nginx service user
RUNHOME="$(getent passwd "$RUNUSER" | cut -d: -f6 || echo "/home/$RUNUSER")"

# App layout
ROOT_DIR="${ROOT_DIR:-/var/www}"
APP_DIR="${APP_DIR:-$ROOT_DIR/devportal}"
SITES_DEFAULT="$APP_DIR/web/sites/default"
PRIVATE_DIR="${PRIVATE_DIR:-$ROOT_DIR/private}"
DOCROOT="${DOCROOT:-$APP_DIR/web}" 
DRUSH="$APP_DIR/vendor/bin/drush"

# Web
# SERVER_NAME="${SERVER_NAME:-_}"   # leave "_" to keep the bundled vhost default (SERVER_NAME:-_)
# WEB_HOST="${WEB_HOST:-10.0.0.10}"     # set to your web server's private IP
# PORT="${PORT:-80}"

# DB
DB_BIND="${DB_BIND:-${DB_HOST:-0.0.0.0}}" 
# DB_NAME="${DB_NAME:-portal}"
# DB_USER="${DB_USER:-portaladmin}"
# DB_PASS="${DB_PASS:-anas!}"
# ROOT_PASS="${ROOT_PASS:-}"        # blank ⇒ socket-auth root
# DB_HOST="${DB_HOST:-127.0.0.1}"
# DB_PORT="${DB_PORT:-3306}"

# Demo content
# INSTALL_DEMO="${INSTALL_DEMO:-0}" # 1 to enable apigee_kickstart_content after install

# Defaults (constants used by the prompts)
DEF_ROLE="all"
DEF_SERVER_NAME="_"         # '_' keeps bundled vhost
DEF_PORT="80"
DEF_WEB_HOST="10.0.0.10"

DEF_DB_HOST="127.0.0.1"
DEF_DB_PORT="3306"
DEF_DB_NAME="portal"
DEF_DB_USER="portaladmin"
DEF_DB_PASS="X7#9qLm*K!p2@zRn#5vE"         # change me in real setups
DEF_ROOT_PASS="${ROOT_PASS:-""}"


# ── Helpers ────────────────────────────────────────────────────────────────
say() { printf "\n\033[1m%s\033[0m\n" "$*"; }

# ── OS ─────────────────────────────────────────────────────────────────────
os_setup() {
  say "OS setup ($OS_NAME)"
  sudo dnf -y update
  sudo dnf -y install epel-release \
    || sudo dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
  sudo dnf -y install https://rpms.remirepo.net/enterprise/remi-release-9.rpm
  sudo dnf makecache
  sudo dnf -y install \
    dnf-plugins-core git zip unzip wget \
    htop vim nano curl bash-completion \
    net-tools tree firewalld gzip bind-utils patch
}

# ── PHP 8.2 ────────────────────────────────────────────────────────────────
php_setup() {
  say "PHP 8.2 setup"
  sudo dnf -y install epel-release \
    || sudo dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
  sudo dnf -y install https://rpms.remirepo.net/enterprise/remi-release-9.rpm
  sudo dnf -qy module reset php
  sudo dnf -qy module enable php:remi-8.2
  sudo dnf -y install \
    php php-bcmath php-cli php-common php-fpm \
    php-gd php-json php-mbstring php-mysqlnd php-opcache \
    php-pdo php-process php-xml php-pgsql php-curl \
    php-intl php-pecl-zip php-pecl-apcu php-pecl-uploadprogress

  # FPM pool → nginx user, 127.0.0.1:9000
  local FPM_CONF=/etc/php-fpm.d/www.conf
  sudo cp -n "$FPM_CONF" "${FPM_CONF}.bak"
  sudo sed -ri \
    -e "s|^user\s*=.*|user = ${WEBUSER}|" \
    -e "s|^group\s*=.*|group = ${WEBGROUP}|" \
    -e 's|^listen\s*=.*|listen = 127.0.0.1:9000|' \
    "$FPM_CONF"

  # Reasonable defaults
  sudo sed -i 's/^memory_limit = .*/memory_limit = 512M/' /etc/php.ini
  sudo tee /etc/php.d/99-opcache.ini >/dev/null <<'INI'
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=192
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=8000
opcache.validate_timestamps=1
opcache.revalidate_freq=2
INI
  sudo tee /etc/php.d/99-apcu.ini >/dev/null <<'INI'
apc.enabled=1
apc.shm_size=64M
INI
  sudo tee /etc/php.d/99-drupal.ini >/dev/null <<'INI'
session.cookie_samesite=Lax
session.cookie_secure=0
INI
  if [ "${DRUPAL_HTTPS:-0}" = "1" ]; then
    sudo sed -i 's/^session\.cookie_secure=.*/session.cookie_secure=1/' /etc/php.d/99-drupal.ini
  fi
  sudo systemctl enable --now php-fpm
  sudo systemctl restart php-fpm
  say "🎉  php stack ready (php $(php -v | head -n1))." 
}

# ── MariaDB 11 ─────────────────────────────────────────────────────────────

# ---------- MariaDB helpers (common) ----------
_mysql() {                       # run mariadb as root (uses ROOT_PASS if set)
  local RA=(-uroot); [[ -n "${ROOT_PASS:-}" ]] && RA=(-uroot "-p${ROOT_PASS}")
  sudo mariadb "${RA[@]}" "$@"
}
_mysqladmin() {
  local RA=(-uroot); [[ -n "${ROOT_PASS:-}" ]] && RA=(-uroot "-p${ROOT_PASS}")
  mariadb-admin "${RA[@]}" "$@"
}

db_install_repo_and_pkgs() {
  sudo dnf -qy module disable mariadb || true
  sudo tee /etc/yum.repos.d/MariaDB.repo >/dev/null <<'EOF'
[mariadb]
name = MariaDB 11
baseurl = https://rpm.mariadb.org/11.4/rhel/$releasever/$basearch
gpgkey  = https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF
  sudo dnf -y install MariaDB-server MariaDB-client
}

db_write_core_config() {          # $1 = bind address
  local BIND="$1"
  sudo tee /etc/my.cnf.d/50-bind.cnf >/dev/null <<EOF
[mysqld]
bind-address=${BIND}
port=${DB_PORT:-3306}
skip_name_resolve=1
EOF
  sudo tee /etc/my.cnf.d/60-maxpacket.cnf >/dev/null <<'EOF'
[mysqld]
max_allowed_packet = 64M
EOF
}

db_start_and_wait() {
  sudo systemctl enable --now mariadb
  sudo systemctl restart mariadb
  for i in {1..30}; do
    _mysqladmin --socket=/var/lib/mysql/mysql.sock ping >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "❌ MariaDB not ready. Check: systemctl status mariadb && journalctl -xeu mariadb"; exit 1
}

db_harden_min() {
  _mysql <<'SQL'
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'127.0.0.1';
DROP USER IF EXISTS ''@'%';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
  if [[ -n "${ROOT_PASS:-}" ]]; then
    sudo mariadb -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASS}'; FLUSH PRIVILEGES;"
  fi
}

db_create_database() {
  _mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL
}

db_grant_local() {
  _mysql <<SQL
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'   IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1'   IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

db_grant_webhost() {              # uses WEB_HOST
  _mysql <<SQL
CREATE USER IF NOT EXISTS '${DB_USER}'@'${WEB_HOST}' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${WEB_HOST}';
FLUSH PRIVILEGES;
SQL
}

db_healthcheck() {
  say "✔  MariaDB $(mariadb --version | awk '{print $5}')"
  _mysqladmin --socket=/var/lib/mysql/mysql.sock ping || true
  command -v ss >/dev/null 2>&1 && ss -ltnp | grep -q ":${DB_PORT:-3306}" || echo "⚠ Not listening on ${DB_PORT:-3306}"
}

# ---------- Orchestrator ----------
db_setup() {
  say "MariaDB 11 setup + Drupal DB"

  # Decide bind address once; common steps stay in helpers
  local BIND_ADDR
  if [[ "${ROLE:-db}" == "all" ]]; then
    BIND_ADDR="${DB_BIND:-127.0.0.1}"         # single-node, local only
  else
    BIND_ADDR="${DB_BIND:-${DB_HOST:-0.0.0.0}}"  # dedicated DB node
  fi

  db_install_repo_and_pkgs
  db_write_core_config "$BIND_ADDR"
  db_start_and_wait
  db_harden_min
  db_create_database
  db_grant_local

  # Only add a remote grant when this node serves a separate web host
  if [[ "${ROLE:-db}" == "db" ]]; then
    db_grant_webhost
  fi

  db_healthcheck
}



# ── Drupal (code only; run installer via UI) ───────────────────────────────
drupal_setup() {
  say "Drupal (Apigee DevPortal Kickstart) codebase"
  id "$RUNUSER" >/dev/null 2>&1 || sudo useradd -m -s /bin/bash -U "$RUNUSER"
  
  RUNHOME="$(getent passwd "$RUNUSER" | cut -d: -f6)"
  : "${RUNHOME:=/home/$RUNUSER}"

  sudo install -d -m 2775 -o "$RUNUSER" -g "$WEBGROUP" "$ROOT_DIR"


  # Composer + Drush launcher
  if ! command -v composer >/dev/null 2>&1; then
    php -r "copy('https://getcomposer.org/installer','composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi
  
  if ! command -v drush >/dev/null 2>&1; then
    sudo wget -qO /usr/local/bin/drush https://github.com/drush-ops/drush-launcher/releases/latest/download/drush.phar
    sudo chmod 755 /usr/local/bin/drush
  fi

  sudo -u "$RUNUSER" install -d "$RUNHOME/.composer" "$RUNHOME/.cache"
  sudo chown -R "$RUNUSER":"$WEBGROUP" "$RUNHOME/.composer" "$RUNHOME/.cache"
#   sudo ln -s /usr/local/bin/composer /usr/bin/composer

  # Optional: DNS pin to Packagist (helpful on some networks)
  if command -v dig >/dev/null 2>&1; then
    local IP
    IP=$(dig +short packagist.org | head -n1 || true)
    [[ -n "$IP" ]] && { grep -qF "packagist.org" /etc/hosts || echo "$IP packagist.org" | sudo tee -a /etc/hosts >/dev/null; }
  fi

  # Backup any previous app dir
  if [[ -d "$APP_DIR" ]]; then
    read -r -p "$APP_DIR exists. 1=Delete  2=Backup  3=Keep : " action
    case "$action" in
      1) sudo rm -rf "$APP_DIR" ;;
      2) sudo mv "$APP_DIR" "${APP_DIR}.$(date +%Y%m%d%H%M%S).backup" ;;
      3) : ;;
      *) echo "Invalid choice – aborting"; exit 1 ;;
    esac
  fi

  # Create project + add Drush (as devportal)
  sudo -u "$RUNUSER" -H bash <<BASH
    set -e
    umask 0002
  
    export HOME="$RUNHOME"
    install -d -m 700 "\$HOME/.composer" "\$HOME/.cache"
  
    cd "$ROOT_DIR"
  
    export COMPOSER_MEMORY_LIMIT=2G
    export XDG_CACHE_HOME="\$HOME/.cache"
    export COMPOSER_HOME="\$HOME/.composer"
  
    command -v /usr/bin/php >/dev/null
    command -v /usr/local/bin/composer >/dev/null
  
    /usr/bin/php /usr/local/bin/composer create-project \
      apigee/devportal-kickstart-project:10.x-dev "$APP_DIR" \
      --no-interaction --no-progress
  
    [ -d "$APP_DIR/web/sites/default" ] || { echo "ERROR: project scaffold missing at $APP_DIR/web/sites/default"; exit 1; }
  
    /usr/bin/php /usr/local/bin/composer --working-dir="$APP_DIR" \
      require drush/drush:^12 -n
  
    [ -x "$APP_DIR/vendor/bin/drush" ] || { echo "ERROR: Drush not found at $APP_DIR/vendor/bin/drush"; exit 1; }
  
    cd "$SITES_DEFAULT"
    [ -f settings.php ] || cp default.settings.php settings.php
    chmod 660 settings.php
BASH

  # Trusted hosts
  local HOST_PCRE
  HOST_PCRE="$(printf '%s' "${SERVER_NAME:-127.0.0.1}" | sed 's/[.[\]{}()*+?^$|\\]/\\&/g')"
  sudo tee -a "$SITES_DEFAULT/settings.php" >/dev/null <<PHP
\$settings['trusted_host_patterns'] = [
  '^localhost$',
  '^127\.0\.0\.1$',
  '^${HOST_PCRE}$',
];
PHP

  # Files & perms
  sudo chown "$RUNUSER":"$WEBGROUP" "$SITES_DEFAULT/settings.php"
  sudo chown -R "$RUNUSER":"$WEBGROUP" "$DOCROOT"
  sudo find "$DOCROOT" -type d -exec chmod 0750 {} \;
  sudo find "$DOCROOT" -type f -exec chmod 0640 {} \;
  sudo find "$APP_DIR/vendor/bin" -type f -exec chmod 0750 {} \;

  sudo install -d -m 2770 -o "$RUNUSER" -g "$WEBGROUP" "$SITES_DEFAULT/files"
  sudo -u "$RUNUSER" install -d "$SITES_DEFAULT/files/media-icons/generic"
  sudo find "$SITES_DEFAULT" -type d -exec chmod 2770 {} \;
  sudo find "$SITES_DEFAULT" -type f -exec chmod 0660 {} \;
  sudo chmod 664 "$SITES_DEFAULT/settings.php"

  # Private files dir
  if [[ -d "$PRIVATE_DIR" ]]; then
    read -r -p "PRIVATE_DIR exists. (1) Delete or (2) Rename to .backup? " a2
    case "$a2" in
      1) sudo rm -rf "$PRIVATE_DIR" ;;
      2) sudo mv "$PRIVATE_DIR" "${PRIVATE_DIR}.backup" ;;
      *) : ;;
    esac
  fi
  sudo install -d -o "$RUNUSER" -g "$WEBGROUP" -m 2770 "$PRIVATE_DIR"
  sudo chown -R "$RUNUSER":"$WEBGROUP" "$SITES_DEFAULT" "$PRIVATE_DIR"
  sudo find "$PRIVATE_DIR" -type d -exec chmod 2770 {} +
  sudo find "$PRIVATE_DIR" -type f -exec chmod 0660 {} +
  echo "\$settings['file_private_path'] = '${PRIVATE_DIR}';" | sudo tee -a "$SITES_DEFAULT/settings.php" >/dev/null

  # # 1) If the commented sample line exists, replace it with a real setting
  # sudo sed -i -E \
  # "s|^#\s*\$settings\['file_private_path'\]\s*=\s*'';|\$settings['file_private_path'] = '${PRIVATE_DIR}';|" \
  # "$SITES_DEFAULT/settings.php"

  # # 2) If there is still no ACTIVE setting, append one
  # sudo grep -Eq "^[[:space:]]*\$settings\['file_private_path'\][[:space:]]*=" "$SITES_DEFAULT/settings.php" \
  # || echo "\$settings['file_private_path'] = '${PRIVATE_DIR}';" | sudo tee -a "$SITES_DEFAULT/settings.php"


  # SELinux (ignore if not enforcing)
  sudo chcon -R -t httpd_sys_rw_content_t "$SITES_DEFAULT" || true
  sudo chcon -R -t httpd_sys_rw_content_t "$SITES_DEFAULT/files" || true
  sudo chcon -R -t httpd_sys_rw_content_t "$SITES_DEFAULT/settings.php" || true
  sudo chcon -R -t httpd_sys_rw_content_t "$PRIVATE_DIR" || true
  sudo setsebool -P httpd_can_network_connect on || true
  sudo setsebool -P httpd_can_network_connect_db on || true

  sudo tee -a "$SITES_DEFAULT/settings.php" >/dev/null <<PHP
    \$databases['default']['default'] = [
    'database' => '$DB_NAME',
    'username' => '$DB_USER',
    'password' => '$DB_PASS',
    'host' => '$DB_HOST',
    'port' => '$DB_PORT',
    'driver' => 'mysql',
    'prefix' => '',
    'collation' => 'utf8mb4_general_ci',
    ];
PHP

  say "Drupal codebase ready at $APP_DIR — proceed to the web installer."
}

# ── Nginx ──────────────────────────────────────────────────────────────────
nginx_setup() {
  say "Nginx setup"
  sudo dnf -y install nginx
  sudo systemctl enable --now nginx
  systemctl is-active --quiet nginx || { echo "❌ Nginx failed to start"; exit 1; }

  # One-time backups
  for f in /etc/nginx/nginx.conf $(find /etc/nginx/conf.d -maxdepth 1 -type f -name '*.conf'); do
    [[ -f ${f}.bkp ]] || sudo cp "$f" "${f}.bkp"
  done

  # Fetch your known-good templates
  sudo curl -fsSL https://raw.githubusercontent.com/ahmedalazazy/auto/main/nginxrhel \
    -o /etc/nginx/nginx.conf
  sudo curl -fsSL https://raw.githubusercontent.com/ahmedalazazy/auto/main/nginxconfigration \
    -o /etc/nginx/conf.d/drupal-nginx.conf

  local VHOST=/etc/nginx/conf.d/drupal-nginx.conf

  # Ensure the root points to our install (keep server_name as-is: '_')
  sudo sed -i -E "s|^\s*root\s+[^;]+;|    root ${DOCROOT};|g" "$VHOST"

  # #  server_name directive
  # if grep -qE '^\s*server_name\s+' "$VHOST"; then
  #   sudo sed -i -E "s|^\s*server_name\s+[^;]+;|    server_name ${SERVER_NAME};|g" "$VHOST"
  # else
  #   sudo sed -i -E "/^\s*listen\s+[0-9]+/a \    server_name ${SERVER_NAME};" "$VHOST"
  # fi

  # Make fastcgi_pass match PHP-FPM
  local PHPFPM_LISTEN
  PHPFPM_LISTEN="$(sed -n 's/^\s*listen\s*=\s*//p' /etc/php-fpm.d/www.conf | head -n1)"
  [[ -z "$PHPFPM_LISTEN" ]] && PHPFPM_LISTEN="127.0.0.1:9000"
  local FCGI_DST
  if [[ "$PHPFPM_LISTEN" == /* ]]; then FCGI_DST="unix:${PHPFPM_LISTEN}"; else FCGI_DST="${PHPFPM_LISTEN}"; fi
  sudo sed -i -E "s|^\s*fastcgi_pass\s+[^;]+;|        fastcgi_pass ${FCGI_DST};|g" "$VHOST"

  ## listen port (preserve default_server if present)
  # sudo sed -i -E "s|^\s*listen\s+([0-9]+)(\s+default_server)?;|    listen ${PORT}\2;|g" "$VHOST"

  # Update only the root directive in the vhost
  if [ -f /etc/nginx/conf.d/drupal-nginx.conf ]; then
    sudo sed -i -E "s|^\s*root\s+[^;]+;|    root ${DOCROOT};|g" /etc/nginx/conf.d/drupal-nginx.conf
  fi

  # (Optional) update any literal path uses elsewhere too
  sudo sed -i -E "s|^\s*root\s+[^;]+;|    root ${DOCROOT};|g" /etc/nginx/conf.d/drupal-nginx.conf
  # sudo sed -i "s|/var/www/devportal/web|$DOCROOT|g" /etc/nginx/nginx.conf /etc/nginx/conf.d/drupal-nginx.conf 2>/dev/null || true

  # # index directive (adds if missing right after root)
  # sudo awk '
  # /^\s*root\s+/ && !seen { print; print "    index index.php index.html;"; seen=1; next }1
  # ' "$VHOST" | sudo tee "$VHOST.tmp" >/dev/null && sudo mv "$VHOST.tmp" "$VHOST"

  # # realpath_root params
  # sudo sed -i -E \
  #   -e "s|^\s*fastcgi_param\s+SCRIPT_FILENAME\s+\$document_root\$fastcgi_script_name;|        fastcgi_param DOCUMENT_ROOT \$realpath_root;\n        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;|g" \
  #   "$VHOST"


  # Allow larger uploads
  grep -q 'client_max_body_size' "$VHOST" || \
    sudo sed -i -E "/^\s*root\s+/a \    client_max_body_size 64m;" "$VHOST"

  # Validate & reload
  if sudo nginx -t; then
    sudo systemctl reload nginx
  else
    echo "❌ Nginx test failed — rolling back"
    for f in /etc/nginx/nginx.conf $(find /etc/nginx/conf.d -maxdepth 1 -type f -name '*.conf'); do
      [[ -f ${f}.bkp ]] && sudo cp -f "${f}.bkp" "$f"
    done
    sudo nginx -t
    exit 1
  fi
  say "Nginx ready."
}

# ── firewalld ──────────────────────────────────────────────────────────────
firewalld_setup() {
  say "firewalld setup"
  sudo dnf -y install firewalld
  sudo systemctl enable --now firewalld
  systemctl is-active --quiet firewalld || { echo "❌ firewalld did not start"; exit 1; }
  sudo firewall-cmd --permanent --add-service={http,https,ssh,mysql,postgresql}
  if [[ "$PORT" != "80" && "$PORT" != "443" ]]; then
    sudo firewall-cmd --permanent --add-port=${PORT}/tcp
  fi
  sudo firewall-cmd --reload
  say "► Current firewall state:"
  sudo firewall-cmd --list-all
  say "✅ firewalld running and required ports open"
}

firewalld_web() {
  sudo dnf -y install firewalld
  sudo systemctl enable --now firewalld
  systemctl is-active --quiet firewalld || { echo "❌ firewalld did not start"; exit 1; }
  sudo firewall-cmd --permanent --add-service={http,https,ssh}
  # web node does NOT expose mysql/postgresql
  sudo firewall-cmd --reload
}

firewalld_db() {
  sudo dnf -y install firewalld
  sudo systemctl enable --now firewalld
  systemctl is-active --quiet firewalld || { echo "❌ firewalld did not start"; exit 1; }
   # figure out the interface that has DB_HOST's IP
  local IFACE
  IFACE="$(ip -o -4 addr show | awk -v ip="$DB_HOST" '$4 ~ ip"/" {print $2; exit}')"
  # pick the zone for that interface (fallback to default zone)
  local ZONE
  ZONE="$(firewall-cmd --get-zone-of-interface "$IFACE" 2>/dev/null || firewall-cmd --get-default-zone)"

  sudo firewall-cmd --zone="$ZONE" --permanent --add-service=ssh
  # lock down 3306 to the web node only
  sudo firewall-cmd --zone="$ZONE" --permanent \
    --add-rich-rule="rule family=ipv4 source address=${WEB_HOST}/32 port protocol=tcp port=${DB_PORT} accept"
  sudo firewall-cmd --reload
#   sudo firewall-cmd --permanent --add-port=${DB_PORT}/tcp
  # lock down to the web host only (adjust zone if needed)
}

# ── post installation ──────────────────────────────────────────────────────────────

remove_deprecated_modules() {

   # Check if admin_toolbar_links_access_filter is installed in core.extension
  if sudo -u "$RUNUSER" "$DRUSH" -r "$DOCROOT" php:eval "echo (int) array_key_exists('admin_toolbar_links_access_filter', \Drupal::config('core.extension')->get('module') ?? []);" | grep -q '^1$'; then
    sudo -u "$RUNUSER" "$DRUSH" -r "$DOCROOT" pm:uninstall admin_toolbar_links_access_filter -y
  else
    echo "Module admin_toolbar_links_access_filter not installed; skipping."
  fi

}

secure_drupal_files() {
  # Lock down settings.php and sites/default
  [ -f "$DOCROOT/sites/default/settings.php" ] && \
    chown "$RUNUSER":"$WEBGROUP" "$DOCROOT/sites/default/settings.php" && \
    chmod 0440 "$DOCROOT/sites/default/settings.php"
  chmod 0555 "$DOCROOT/sites/default" || true
}

drupal_post_installation() {
  if ! sudo -u "$RUNUSER" "$DRUSH" -r "$DOCROOT" status --fields=bootstrap --format=list 2>/dev/null | grep -q 'Successful'; then
    echo "Drupal not installed yet; skipping post-installation."
    return 0
  fi
  remove_deprecated_modules
  secure_drupal_files
#   apigee_key_setup
  # Finalize
  sudo -u "$RUNUSER" "$DRUSH" --root="$DOCROOT" cr -y
  sudo -u "$RUNUSER" "$DRUSH" --root="$DOCROOT" status
}

# identities_setup() {
#   getent group "$WEBGROUP" >/dev/null || sudo groupadd "$WEBGROUP"
#   id "$RUNUSER" >/dev/null 2>&1 || sudo useradd -m -s /bin/bash -g "$WEBGROUP" "$RUNUSER"
#   getent passwd "$WEBUSER" >/dev/null || sudo useradd --system --home /var/lib/"$WEBUSER" --shell /sbin/nologin "$WEBUSER"
# }

_is_false()   { [[ "$1" =~ ^(false|0|no)$ ]]; }
_valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 1 <= $1 && $1 <= 65535 )); }
_valid_role() { [[ "$1" =~ ^(web|db|all)$ ]]; }

# Prompt only if the variable is UNSET or EMPTY.
# $1=VAR  $2=Label  $3=Default
ask_if_missing() {
  local var="$1" label="$2" def="$3" in
  # If already provided (env or earlier), do nothing.
  if [[ -n "${!var+x}" && -n "${!var}" ]]; then return 0; fi

  # Non-interactive or no TTY → silently apply default
  if _is_false "$INTERACTIVE" || [[ ! -t 0 ]]; then
    printf -v "$var" "%s" "$def"
    return 0
  fi

  # Interactive prompt
  read -r -p "${label} [${def}]: " in
  printf -v "$var" "%s" "${in:-$def}"
}

# Secret prompt variant (hides input). Default is applied if Enter.
ask_secret_if_missing() {
  local var="$1" label="$2" def="$3" in
  if [[ -n "${!var+x}" && -n "${!var}" ]]; then return 0; fi
  if _is_false "$INTERACTIVE" || [[ ! -t 0 ]]; then
    printf -v "$var" "%s" "$def"
    return 0
  fi
  read -r -s -p "${label} [hidden, press Enter for default]: " in; echo
  printf -v "$var" "%s" "${in:-$def}"
}

# Suggestions for nicer defaults
_suggest_server_name() { hostname -f 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'; }



collect_config() {
  # 1) Role first
  ask_if_missing ROLE "Node ROLE (web|db|all)" "${DEF_ROLE}"
  _valid_role "$ROLE" || { echo "Invalid ROLE '$ROLE' (use web|db|all)"; exit 2; }

  # 2) Web vhost bits (only on web/all)
  if [[ "$ROLE" == "web" || "$ROLE" == "all" ]]; then
    ask_if_missing SERVER_NAME "SERVER_NAME (FQDN or IPv4; '_' keeps bundled vhost)" "${DEF_SERVER_NAME}"
    ask_if_missing PORT        "HTTP PORT"                                           "${DEF_PORT}"
    _valid_port "$PORT" || { echo "Invalid PORT '$PORT'"; exit 2; }
  fi

  # 3) DB params shared by web and db roles
  #    (Drupal needs them; DB node needs them to create grants)
  ask_if_missing DB_HOST "DB_HOST (MySQL host)" "${DEF_DB_HOST}"
  ask_if_missing DB_PORT "DB_PORT" "${DEF_DB_PORT}"
  _valid_port "$DB_PORT" || { echo "Invalid DB_PORT '$DB_PORT'"; exit 2; }
  ask_if_missing        DB_NAME "DB_NAME" "${DEF_DB_NAME}"
  ask_if_missing        DB_USER "DB_USER" "${DEF_DB_USER}"
  ask_secret_if_missing DB_PASS "DB_PASS" "${DEF_DB_PASS}"

  # 4) DB-node–only items
  if [[ "$ROLE" == "db" || "$ROLE" == "all" ]]; then
    ask_if_missing        WEB_HOST  "WEB_HOST allowed to DB (IPv4)" "${DEF_WEB_HOST}"
    ask_secret_if_missing ROOT_PASS "ROOT_PASS for MariaDB (optional)" "${DEF_ROOT_PASS}"
  fi
}


cleanup() {
  unset -f os_setup php_setup db_setup drupal_setup nginx_setup firewalld_setup \
            collect_config drupal_post_installation main
  # Optionally unset globals too:
  unset OS_NAME ROLE RUNUSER WEBGROUP WEBUSER ROOT_DIR APP_DIR DOCROOT SERVER_NAME DB_HOST DB_PORT
}



# ── Main ───────────────────────────────────────────────────────────────────
main() {
  collect_config   # prompts only for missing vars, otherwise keeps what you passed
  os_setup

  case "$ROLE" in
    web)
      php_setup; drupal_setup; nginx_setup; firewalld_web
      ;;
    db)
      db_setup; firewalld_db
      ;;
    all)
      php_setup; db_setup; drupal_setup; nginx_setup; firewalld_setup
      ;;
    *)
      echo "Invalid ROLE=$ROLE (use web|db|all)"; exit 2 ;;
  esac

  # [[ "${BASH_SOURCE[0]}" != "$0" ]] && cleanup
}


main "$@"

