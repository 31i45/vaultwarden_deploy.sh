#!/bin/bash
set -euo pipefail

# 基础配置（用户可按需修改这部分）
APP_NAME="vaultwarden"
APP_DIR="$HOME/$APP_NAME"
DATA_DIR="$APP_DIR/data"      # 数据持久化目录
SSL_DIR="$APP_DIR/ssl"        # 证书目录
PORT=8443                     # 访问端口
DOMAIN="localhost"            # 域名（默认为本地）

# 颜色与样式
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m" # 无颜色
BOLD=$(tput bold)
NORMAL=$(tput sgr0)

# 日志函数
info() { echo -e "${GREEN}• $1${NC}"; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}"; exit 1; }

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 1. 检查系统依赖
check_dependencies() {
    info "检查系统依赖"

    # 检查Docker
    if ! command_exists docker; then
        info "安装Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh >/dev/null 2>&1
        sudo usermod -aG docker "$USER"
        rm get-docker.sh
        warn "Docker已安装，需要重新登录生效"
        info "请注销当前用户后重新运行此脚本"
        exit 0
    fi

    # 检查Docker Compose
    if ! docker compose version >/dev/null 2>&1; then
        info "安装Docker Compose..."
        if command_exists apt; then
            sudo apt update -qq >/dev/null
            sudo apt install -y -qq docker-compose-plugin >/dev/null
        elif command_exists yum; then
            sudo yum install -y -q docker-compose-plugin >/dev/null
        else
            error "不支持的包管理器，请手动安装docker-compose-plugin"
        fi
    fi

    # 检查openssl（用于生成证书）
    if ! command_exists openssl; then
        info "安装openssl..."
        if command_exists apt; then
            sudo apt install -y -qq openssl >/dev/null
        elif command_exists yum; then
            sudo yum install -y -q openssl >/dev/null
        else
            error "不支持的包管理器，请手动安装openssl"
        fi
    fi
    
    # 检查argon2（用于加密令牌）
    if ! command_exists argon2; then
    	info "安装 argon2..."
    	if command_exists apt; then
            sudo apt install -y -qq argon2 >/dev/null
    	elif command_exists yum; then
            sudo yum install -y -q argon2 >/dev/null
    	else
            error "不支持的包管理器，请手动安装 argon2"
    	fi
    fi
}

# 2. 初始化目录结构
init_directories() {
    info "初始化目录结构"
    mkdir -p "$DATA_DIR" "$SSL_DIR"
    chmod 700 "$APP_DIR" "$DATA_DIR" "$SSL_DIR"  # 严格权限控制
}

# 3. 生成安全配置
generate_configs() {
    info "生成安全配置"

    # 生成管理员令牌（仅首次部署）
    ENV_FILE="$APP_DIR/.env"
    if [ ! -f "$ENV_FILE" ]; then
	info "生成并加密管理员令牌..."
        # 使用 Bitwarden 默认的 Argon2 加密参数生成令牌
        # 生成随机盐值（确保长度至少8且无换行符）
        SALT=$(openssl rand -base64 32 | tr -d '\n' | cut -c1-16)
        # 生成原始令牌（用于用户登录）
        RAW_TOKEN=$(openssl rand -base64 48 | tr -d '\n')
        # 使用Argon2加密原始令牌（用于存储和验证）
        ENCRYPTED_TOKEN=$(echo -n "$RAW_TOKEN" | argon2 "$SALT" -e -id -m 16 -t 3 -p 4)
        ESCAPED_TOKEN=$(echo -n "$ENCRYPTED_TOKEN" | sed 's#\$#\$\$#g')
        
        # 检查令牌生成是否成功（验证加密令牌格式）
        if [ -z "$ESCAPED_TOKEN" ] ||!(echo "$ESCAPED_TOKEN" | grep -q '^\$$argon2id\$'); then
            error "Argon2 加密失败，请确保系统已安装 argon2"
        fi

        # 写入.env文件（存储加密令牌）
        cat > "$ENV_FILE" <<EOF
ADMIN_TOKEN=$ESCAPED_TOKEN
SIGNUPS_ALLOWED=true
INVITATIONS_ALLOWED=true
DOMAIN=https://$DOMAIN:$PORT
EOF
        chmod 600 "$ENV_FILE"  # 仅所有者可读写
        warn "管理员令牌已生成，加密版本保存在 $ENV_FILE"
        warn "请记录以下原始令牌（仅显示一次，用于登录管理员界面）："
        echo -e "${BOLD}$RAW_TOKEN${NORMAL}"
        read -p "确认已记录令牌 [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "请重新运行脚本并记录令牌"
        fi
    fi

    # 生成SSL证书（仅首次部署）
    if [ ! -f "$SSL_DIR/cert.pem" ] || [ ! -f "$SSL_DIR/key.pem" ]; then
        info "生成SSL证书..."
        openssl req -x509 -newkey rsa:4096 -nodes \
            -keyout "$SSL_DIR/key.pem" \
            -out "$SSL_DIR/cert.pem" \
            -days 3650 \
            -subj "/CN=$DOMAIN" >/dev/null 2>&1 || {
            error "证书生成失败，请检查openssl是否正常工作"
        }
        chmod 600 "$SSL_DIR"/*
    fi

    # 生成docker-compose配置（使用env_file加载环境变量）
    COMPOSE_FILE="$APP_DIR/docker-compose.yml"
    cat > "$COMPOSE_FILE" <<EOF
services:
  $APP_NAME:
    image: vaultwarden/server:latest
    container_name: $APP_NAME
    restart: always
    security_opt:
      - no-new-privileges:true
    env_file:
      - "$ENV_FILE"
    environment:
      - ENABLE_HTTPS=true
      - ROCKET_TLS={certs="/ssl/cert.pem",key="/ssl/key.pem"}
      - ROCKET_PORT=443  # 明确指定HTTPS端口为443
    volumes:
      - $DATA_DIR:/data
      - $SSL_DIR:/ssl
    ports:
      - "$PORT:443"
    healthcheck:
      test: ["CMD", "curl", "-k", "--silent", "--show-error", "--fail", "https://localhost:443/health"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF
}

# 4. 启动服务
start_service() {
    info "启动Vaultwarden服务"
    cd "$APP_DIR" && docker compose up -d

    # 等待服务就绪
    info "等待服务初始化（约10秒）..."
    for i in {1..10}; do
        if docker compose exec -T "$APP_NAME" curl -k -s "https://localhost:443/health" >/dev/null; then
            break
        fi
        sleep 1
    done

    # 显示访问信息
    local IP=$(hostname -I | awk '{print $1}')
    info "部署完成！"
    echo -e "访问地址: ${BOLD}https://$IP:$PORT${NORMAL}"
    echo -e "用户注册：${BOLD}https://$IP:$PORT/#/signup${NORMAL}"
    echo -e "管理员界面: ${BOLD}https://$IP:$PORT/admin${NORMAL}"
    warn "首次访问会提示证书不安全，这是正常现象（自签名证书）"
}

# 5. 备份功能（可选执行）
backup_data() {
    if [ "$1" = "backup" ]; then
        info "创建数据备份"
        BACKUP_DIR="$APP_DIR/backups"
        mkdir -p "$BACKUP_DIR"
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        docker compose exec -T "$APP_NAME" sqlite3 /data/db.sqlite3 ".backup /data/backup_$TIMESTAMP.sqlite3"
        mv "$DATA_DIR/backup_$TIMESTAMP.sqlite3" "$BACKUP_DIR/"
        info "备份已保存至: $BACKUP_DIR/backup_$TIMESTAMP.sqlite3"

        # 清理30天前的备份
        find "$BACKUP_DIR" -name "backup_*.sqlite3" -mtime +30 -delete
    fi
}

# 主流程
main() {
    echo -e "${BOLD}Vaultwarden 部署工具${NORMAL}\n"

    check_dependencies
    init_directories
    generate_configs
    start_service

    # 如需自动备份，取消下一行注释（每天凌晨3点执行）
    # (crontab -l 2>/dev/null | grep -v -F "$0 backup" ; echo "0 3 * * * $0 backup") | crontab -
}

# 执行主流程或备份
if [ $# -eq 1 ] && [ "$1" = "backup" ]; then
    backup_data "backup"
else
    main
fi