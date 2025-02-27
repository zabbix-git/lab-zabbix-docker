#!/bin/bash

set -o pipefail

set +e

# Script trace mode
if [ "${DEBUG_MODE}" == "true" ]; then
    set -o xtrace
fi

# Default Zabbix installation name
# Used only by Zabbix web-interface
ZBX_SERVER_NAME=${ZBX_SERVER_NAME:-"SERVER_NAME"}
# Default Zabbix server host
ZBX_SERVER_HOST=${ZBX_SERVER_HOST:-"IP_SERVER"}
# Default Zabbix server port number
ZBX_SERVER_PORT=${ZBX_SERVER_PORT:-"10051"}

# Default directories
# User 'zabbix' home directory
ZABBIX_USER_HOME_DIR="/var/lib/zabbix"
# Configuration files directory
ZABBIX_ETC_DIR="/etc/zabbix"
# Web interface www-root directory
ZBX_FRONTEND_PATH="/usr/share/zabbix"

# usage: file_env VAR [DEFAULT]
# as example: file_env 'MYSQL_PASSWORD' 'zabbix'
#    (will allow for "$MYSQL_PASSWORD_FILE" to fill in the value of "$MYSQL_PASSWORD" from a file)
# unsets the VAR_FILE afterwards and just leaving VAR
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local defaultValue="${2:-}"

    if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
        echo "**** Both variables $var and $fileVar are set (but are exclusive)"
        exit 1
    fi

    local val="$defaultValue"

    if [ "${!var:-}" ]; then
        val="${!var}"
        echo "** Using ${var} variable from ENV"
    elif [ "${!fileVar:-}" ]; then
        if [ ! -f "${!fileVar}" ]; then
            echo "**** Secret file \"${!fileVar}\" is not found"
            exit 1
        fi
        val="$(< "${!fileVar}")"
        echo "** Using ${var} variable from secret file"
    fi
    export "$var"="$val"
    unset "$fileVar"
}

# Check prerequisites for MySQL database
check_variables() {
    : ${DB_SERVER_HOST:="IP_BD"}
    : ${DB_SERVER_PORT:="3306"}
    USE_DB_ROOT_USER=false
    CREATE_ZBX_DB_USER=false
    file_env MYSQL_USER
    file_env MYSQL_PASSWORD

    if [ ! -n "${MYSQL_USER}" ] && [ "${MYSQL_RANDOM_ROOT_PASSWORD}" == "true" ]; then
        echo "**** Impossible to use MySQL server because of unknown Zabbix user and random 'root' password"
        exit 1
    fi

    if [ ! -n "${MYSQL_USER}" ] && [ ! -n "${MYSQL_ROOT_PASSWORD}" ] && [ "${MYSQL_ALLOW_EMPTY_PASSWORD}" != "true" ]; then
        echo "*** Impossible to use MySQL server because 'root' password is not defined and it is not empty"
        exit 1
    fi

    if [ "${MYSQL_ALLOW_EMPTY_PASSWORD}" == "true" ] || [ -n "${MYSQL_ROOT_PASSWORD}" ]; then
        USE_DB_ROOT_USER=true
        DB_SERVER_ROOT_USER="root"
        DB_SERVER_ROOT_PASS=${MYSQL_ROOT_PASSWORD}
    fi

    [ -n "${MYSQL_USER}" ] && CREATE_ZBX_DB_USER=true

    # If root password is not specified use provided credentials
    : ${DB_SERVER_ROOT_USER:=${MYSQL_USER}}
    [ "${MYSQL_ALLOW_EMPTY_PASSWORD}" == "true" ] || DB_SERVER_ROOT_PASS=${DB_SERVER_ROOT_PASS:-${MYSQL_PASSWORD}}
    DB_SERVER_ZBX_USER=${MYSQL_USER:-"FRONTENDUSER_BD"}
    DB_SERVER_ZBX_PASS=${MYSQL_PASSWORD:-"PASS_FRONTENDUSER_BD"}

    DB_SERVER_DBNAME=${MYSQL_DATABASE:-"zabbix"}
}

db_tls_params() {
    local result=""

    if [ "${ZBX_DB_ENCRYPTION}" == "true" ]; then
        result="--ssl-mode=required"

        if [ -n "${ZBX_DB_CA_FILE}" ]; then
            result="${result} --ssl-ca=${ZBX_DB_CA_FILE}"
        fi

        if [ -n "${ZBX_DB_KEY_FILE}" ]; then
            result="${result} --ssl-key=${ZBX_DB_KEY_FILE}"
        fi

        if [ -n "${ZBX_DB_CERT_FILE}" ]; then
            result="${result} --ssl-cert=${ZBX_DB_CERT_FILE}"
        fi
    fi

    echo $result
}

check_db_connect() {
    echo "********************"
    echo "* DB_SERVER_HOST: ${DB_SERVER_HOST}"
    echo "* DB_SERVER_PORT: ${DB_SERVER_PORT}"
    echo "* DB_SERVER_DBNAME: ${DB_SERVER_DBNAME}"
    if [ "${DEBUG_MODE}" == "true" ]; then
        if [ "${USE_DB_ROOT_USER}" == "true" ]; then
            echo "* DB_SERVER_ROOT_USER: ${DB_SERVER_ROOT_USER}"
            echo "* DB_SERVER_ROOT_PASS: ${DB_SERVER_ROOT_PASS}"
        fi
        echo "* DB_SERVER_ZBX_USER: ${DB_SERVER_ZBX_USER}"
        echo "* DB_SERVER_ZBX_PASS: ${DB_SERVER_ZBX_PASS}"
        echo "********************"
    fi
    echo "********************"

    WAIT_TIMEOUT=5

    ssl_opts="$(db_tls_params)"

    export MYSQL_PWD="${DB_SERVER_ROOT_PASS}"

    while [ ! "$(mysqladmin ping -h ${DB_SERVER_HOST} -P ${DB_SERVER_PORT} -u ${DB_SERVER_ROOT_USER} \
                --silent --connect_timeout=10 $ssl_opts)" ]; do
        echo "**** MySQL server is not available. Waiting $WAIT_TIMEOUT seconds..."
        sleep $WAIT_TIMEOUT
    done

    unset MYSQL_PWD
}

prepare_web_server() {
    NGINX_CONFD_DIR="/etc/nginx/conf.d"
    NGINX_SSL_CONFIG="/etc/ssl/nginx"

    echo "** Adding Zabbix virtual host (HTTP)"
    if [ -f "$ZABBIX_ETC_DIR/nginx.conf" ]; then
        ln -s "$ZABBIX_ETC_DIR/nginx.conf" "$NGINX_CONFD_DIR"
    else
        echo "**** Impossible to enable HTTP virtual host"
    fi

    if [ -f "$NGINX_SSL_CONFIG/ssl.crt" ] && [ -f "$NGINX_SSL_CONFIG/ssl.key" ] && [ -f "$NGINX_SSL_CONFIG/dhparam.pem" ]; then
        echo "** Enable SSL support for Nginx"
        if [ -f "$ZABBIX_ETC_DIR/nginx_ssl.conf" ]; then
            ln -s "$ZABBIX_ETC_DIR/nginx_ssl.conf" "$NGINX_CONFD_DIR"
        else
            echo "**** Impossible to enable HTTPS virtual host"
        fi
    else
        echo "**** Impossible to enable SSL support for Nginx. Certificates are missed."
    fi
}

prepare_zbx_web_config() {
    echo "** Preparing Zabbix frontend configuration file"

    PHP_CONFIG_FILE="/etc/php-fpm.d/zabbix.conf"

    if [ "$(id -u)" == '0' ]; then
        echo "user = zabbix" >> "$PHP_CONFIG_FILE"
        echo "group = zabbix" >> "$PHP_CONFIG_FILE"
        echo "listen.owner = nginx" >> "$PHP_CONFIG_FILE"
        echo "listen.group = nginx" >> "$PHP_CONFIG_FILE"
    fi

    export ZBX_DENY_GUI_ACCESS=${ZBX_DENY_GUI_ACCESS:-"false"}
    export ZBX_GUI_ACCESS_IP_RANGE=${ZBX_GUI_ACCESS_IP_RANGE:-"['127.0.0.1']"}
    export ZBX_GUI_WARNING_MSG=${ZBX_GUI_WARNING_MSG:-"Zabbix is under maintenance."}

    export ZBX_MAXEXECUTIONTIME=${ZBX_MAXEXECUTIONTIME:-"600"}
    export ZBX_MEMORYLIMIT=${ZBX_MEMORYLIMIT:-"128M"}
    export ZBX_POSTMAXSIZE=${ZBX_POSTMAXSIZE:-"16M"}
    export ZBX_UPLOADMAXFILESIZE=${ZBX_UPLOADMAXFILESIZE:-"2M"}
    export ZBX_MAXINPUTTIME=${ZBX_MAXINPUTTIME:-"300"}
    export PHP_TZ=${PHP_TZ:-"America/Sao_Paulo"}

    export DB_SERVER_TYPE="MYSQL"
    export DB_SERVER_HOST=${DB_SERVER_HOST}
    export DB_SERVER_PORT=${DB_SERVER_PORT}
    export DB_SERVER_DBNAME=${DB_SERVER_DBNAME}
    export DB_SERVER_SCHEMA=${DB_SERVER_SCHEMA}
    export DB_SERVER_USER=${DB_SERVER_ZBX_USER}
    export DB_SERVER_PASS=${DB_SERVER_ZBX_PASS}
    export ZBX_SERVER_HOST=${ZBX_SERVER_HOST}
    export ZBX_SERVER_PORT=${ZBX_SERVER_PORT:-"10051"}
    export ZBX_SERVER_NAME=${ZBX_SERVER_NAME}

    export ZBX_DB_ENCRYPTION=${ZBX_DB_ENCRYPTION:-"false"}
    export ZBX_DB_KEY_FILE=${ZBX_DB_KEY_FILE}
    export ZBX_DB_CERT_FILE=${ZBX_DB_CERT_FILE}
    export ZBX_DB_CA_FILE=${ZBX_DB_CA_FILE}
    export ZBX_DB_VERIFY_HOST=${ZBX_DB_VERIFY_HOST-"false"}

    export ZBX_VAULTURL=${ZBX_VAULTURL}
    export ZBX_VAULTDBPATH=${ZBX_VAULTDBPATH}
    export VAULT_TOKEN=${VAULT_TOKEN}

    export DB_DOUBLE_IEEE754=${DB_DOUBLE_IEEE754:-"true"}

    export ZBX_HISTORYSTORAGEURL=${ZBX_HISTORYSTORAGEURL}
    export ZBX_HISTORYSTORAGETYPES=${ZBX_HISTORYSTORAGETYPES:-"[]"}

    export ZBX_SSO_SETTINGS=${ZBX_SSO_SETTINGS:-""}

    if [ -n "${ZBX_SESSION_NAME}" ]; then
        cp "$ZBX_FRONTEND_PATH/include/defines.inc.php" "/tmp/defines.inc.php_tmp"
        sed "/ZBX_SESSION_NAME/s/'[^']*'/'${ZBX_SESSION_NAME}'/2" "/tmp/defines.inc.php_tmp" > "$ZBX_FRONTEND_PATH/include/defines.inc.php"
        rm -f "/tmp/defines.inc.php_tmp"
    fi

    FCGI_READ_TIMEOUT=$(expr ${ZBX_MAXEXECUTIONTIME} + 1)
    sed -i \
        -e "s/{FCGI_READ_TIMEOUT}/${FCGI_READ_TIMEOUT}/g" \
    "$ZABBIX_ETC_DIR/nginx.conf"

    if [ -f "$ZABBIX_ETC_DIR/nginx_ssl.conf" ]; then
        sed -i \
            -e "s/{FCGI_READ_TIMEOUT}/${FCGI_READ_TIMEOUT}/g" \
        "$ZABBIX_ETC_DIR/nginx_ssl.conf"
    fi

    if [ "${ENABLE_WEB_ACCESS_LOG:-"true"}" == "false" ]; then
        sed -ri \
            -e 's!^(\s*access_log).+\;!\1 off\;!g' \
            "/etc/nginx/nginx.conf"
        sed -ri \
            -e 's!^(\s*access_log).+\;!\1 off\;!g' \
            "/etc/zabbix/nginx.conf"
        sed -ri \
            -e 's!^(\s*access_log).+\;!\1 off\;!g' \
            "/etc/zabbix/nginx_ssl.conf"
    fi
}

#################################################

echo "** Deploying Zabbix web-interface (Nginx) with MySQL database"

check_variables
check_db_connect
prepare_web_server
prepare_zbx_web_config

echo "########################################################"

if [ "$1" != "" ]; then
    echo "** Executing '$@'"
    exec "$@"
elif [ -f "/usr/bin/supervisord" ]; then
    echo "** Executing supervisord"
    exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
else
    echo "Unknown instructions. Exiting..."
    exit 1
fi

#################################################