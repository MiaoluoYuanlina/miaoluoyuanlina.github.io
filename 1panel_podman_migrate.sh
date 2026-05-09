#!/bin/bash

# 设置遇到错误即暂停/停止
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}===============================================================${NC}"
echo -e "${GREEN}>>> 开始 Docker 到 Podman 的【深度完全替换】(修复网络与迁移时序)...${NC}"
echo -e "${CYAN}===============================================================${NC}"

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误: 请以 root 权限运行此脚本${NC}"
    exit 1
fi

# 1. 仅安装 Podman 核心依赖 (暂不安装 podman-docker 以免提前卸载原版 Docker)
echo -e "${GREEN}[1/8] 正在安装 Podman 核心组件...${NC}"
apt update
apt install -y podman apparmor-utils slirp4netns uidmap fuse-overlayfs curl || {
    echo -e "${RED}安装失败，请检查网络或软件源。${NC}"
    exit 1
}

# 2. 镜像迁移 (在原版 Docker 还活着的时候进行)
echo -e "${YELLOW}是否尝试将当前 Docker 镜像迁移到 Podman? (y/n)${NC}"
read -r migrate_choice
if [[ "$migrate_choice" =~ ^[Yy]$ ]]; then
    # 检查原版 Docker 是否还在运行
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
        echo -e "${GREEN}[2/8] 正在从 Docker 导出并导入到 Podman (可能需要较长时间)...${NC}"
        IMAGES=$(docker images -q 2>/dev/null || true)
        if [ -n "$IMAGES" ]; then
            for img in $IMAGES; do
                echo "正在迁移镜像: $img"
                docker save "$img" | podman load || echo -e "${YELLOW}警告: 镜像 $img 迁移失败，跳过...${NC}"
            done
        else
            echo -e "${YELLOW}未检测到现有镜像，跳过迁移。${NC}"
        fi
    else
        echo -e "${YELLOW}未检测到运行中的 Docker 服务，可能已被卸载或未启动，跳过迁移。${NC}"
    fi
else
    echo -e "${GREEN}[2/8] 用户选择跳过镜像迁移。${NC}"
fi

# 3. 安装命令伪装层并接管系统服务
echo -e "${GREEN}[3/8] 安装伪装层并彻底停止原版 Docker...${NC}"
# 这一步会自动卸载 docker-ce 和 docker-ce-cli
apt install -y podman-docker

systemctl stop docker docker.socket containerd >/dev/null 2>&1 || true
systemctl disable docker docker.socket containerd >/dev/null 2>&1 || true

# 4. 路径深度伪装 (/var/lib/docker & /etc/docker)
echo -e "${GREEN}[4/8] 执行路径深度伪装...${NC}"
TIMESTAMP=$(date +%s)

if [ -d "/var/lib/docker" ] && [ ! -L "/var/lib/docker" ]; then
    echo "备份原 Docker 存储目录到 /var/lib/docker.bak.$TIMESTAMP"
    mv /var/lib/docker /var/lib/docker.bak.$TIMESTAMP
fi
mkdir -p /var/lib/containers/storage
ln -sfn /var/lib/containers/storage /var/lib/docker

if [ -d "/etc/docker" ] && [ ! -L "/etc/docker" ]; then
    echo "备份原 Docker 配置目录到 /etc/docker.bak.$TIMESTAMP"
    mv /etc/docker /etc/docker.bak.$TIMESTAMP
fi
mkdir -p /etc/containers
ln -sfn /etc/containers /etc/docker

# 5. API Socket 伪装
echo -e "${GREEN}[5/8] 配置 Podman API 伪装 Docker Socket...${NC}"
if [ -S "/var/run/docker.sock" ] || [ -e "/var/run/docker.sock" ]; then
    mv /var/run/docker.sock /var/run/docker.sock.bak.$TIMESTAMP 2>/dev/null || rm -f /var/run/docker.sock
fi
systemctl enable --now podman.socket
ln -sf /run/podman/podman.sock /var/run/docker.sock

# 6. Docker Compose 编排伪装 (修复网络下载问题)
echo -e "${GREEN}[6/8] 部署 Docker Compose 兼容层...${NC}"
ARCH=$(uname -m)
if [ "$ARCH" == "x86_64" ]; then COMPOSE_ARCH="x86_64"; elif [ "$ARCH" == "aarch64" ]; then COMPOSE_ARCH="aarch64"; else COMPOSE_ARCH="x86_64"; fi

# 备用下载链接，防止 GitHub 被墙
COMPOSE_URLS=(
    "https://mirror.ghproxy.com/https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}"
    "https://ghp.ci/https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}"
    "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}"
)

DOWNLOAD_SUCCESS=false
for url in "${COMPOSE_URLS[@]}"; do
    echo -e "尝试下载 Compose: ${CYAN}$url${NC}"
    # 临时关闭错误即退出，允许 curl 失败
    set +e 
    curl -SL --connect-timeout 10 -m 60 "$url" -o /usr/local/bin/docker-compose
    CURL_STATUS=$?
    set -e
    
    # 检查文件是否成功下载且大小大于10MB (防止下到错误页面)
    if [ $CURL_STATUS -eq 0 ] && [ -s /usr/local/bin/docker-compose ] && [ $(stat -c%s /usr/local/bin/docker-compose) -gt 10000000 ]; then
        DOWNLOAD_SUCCESS=true
        break
    else
        echo -e "${YELLOW}下载失败或不完整，尝试下一个节点...${NC}"
        rm -f /usr/local/bin/docker-compose
    fi
done

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo -e "${RED}严重错误: Docker Compose 下载失败，请检查服务器网络是否能访问外网。${NC}"
    exit 1
fi

chmod +x /usr/local/bin/docker-compose
mkdir -p /usr/local/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins
ln -sfn /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
ln -sfn /usr/local/bin/docker-compose /usr/libexec/docker/cli-plugins/docker-compose

# 7. 权限与自启动优化
echo -e "${GREEN}[7/8] 优化容器网络与自启动机制...${NC}"
echo "net.ipv4.ip_unprivileged_port_start=0" > /etc/sysctl.d/podman-ports.conf
sysctl --system >/dev/null 2>&1
systemctl enable --now podman-restart.service

# 8. 镜像加速器配置
echo -e "${YELLOW}是否配置 Podman 镜像加速器? (y/n)${NC}"
read -r config_mirror
if [[ "$config_mirror" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}[8/8] 正在写入镜像加速配置...${NC}"
    tee /etc/containers/registries.conf > /dev/null <<-'EOF'
unqualified-search-registries = ["docker.io", "quay.io"]

[[registry]]
prefix = "docker.io"
location = "docker.io"

[[registry.mirror]]
location = "dockerpull.com"

[[registry.mirror]]
location = "docker.1panel.live"

[[registry.mirror]]
location = "mirror.baidubce.com"
EOF
    systemctl restart podman
    echo "镜像加速器配置完毕。"
else
    echo -e "${GREEN}[8/8] 跳过镜像加速配置。${NC}"
fi

# 9. 全面验证
echo -e "${CYAN}===============================================================${NC}"
echo -e "${GREEN}>>> 验证深度替换结果:${NC}"

if docker --version | grep -qi "podman"; then
    echo -e "✅ Docker Client 伪装: ${GREEN}成功 (由 Podman 接管)${NC}"
else
    echo -e "❌ Docker Client 伪装: ${RED}失败${NC}"
fi

if docker compose version >/dev/null 2>&1; then
    echo -e "✅ Docker Compose 伪装: ${GREEN}成功${NC}"
else
    echo -e "❌ Docker Compose 伪装: ${RED}失败${NC}"
fi

if [ -S /var/run/docker.sock ]; then
    echo -e "✅ Docker API Socket 伪装: ${GREEN}成功${NC}"
else
    echo -e "❌ Docker API Socket 伪装: ${RED}失败${NC}"
fi

if [ -L /var/lib/docker ] && [ -L /etc/docker ]; then
    echo -e "✅ Docker 核心路径伪装: ${GREEN}成功${NC}"
else
    echo -e "❌ Docker 核心路径伪装: ${RED}失败${NC}"
fi

echo -e "${CYAN}===============================================================${NC}"
echo -e "${GREEN}🎉 深度替换完成！${NC}"
echo -e "1. 您的系统现在完全由 Podman 驱动，但所有外部程序都会认为 Docker 仍在运行。"
echo -e "2. ${YELLOW}请重启 1Panel 服务以应用新环境: systemctl restart 1panel${NC}"
echo -e "3. 请登录 1Panel 面板，检查容器、应用商店是否正常工作。"
echo -e "4. 原来的 Docker 数据已备份至 /var/lib/docker.bak.时间戳"
echo -e "${CYAN}===============================================================${NC}"
