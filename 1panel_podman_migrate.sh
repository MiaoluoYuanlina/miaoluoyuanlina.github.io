#!/bin/bash

# 设置遇到错误即停止
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}>>> 开始 Docker 到 Podman 的全自动转换 (Debian 13 / 1Panel 适配)...${NC}"

# 1. 检查权限
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误: 请以 root 权限运行此脚本${NC}"
    exit 1
fi

# 2. 确认系统版本
if [[ ! $(cat /etc/debian_version) =~ "13" ]]; then
    echo -e "${YELLOW}警告: 检测到非 Debian 13 系统，脚本将尝试继续，但不保证兼容性。${NC}"
    read -p "按回车继续，或 Ctrl+C 退出..."
fi

# 3. 安装 Podman 及相关组件
echo -e "${GREEN}正在安装 Podman 组件...${NC}"
apt update
apt install -y podman podman-docker apparmor-utils slirp4netns uidmap fuse-overlayfs || {
    echo -e "${RED}安装失败，请检查网络或软件源。${NC}"
    exit 1
}

# 4. 停止并禁用 Docker 服务
echo -e "${GREEN}正在停止 Docker 服务...${NC}"
if systemctl is-active --quiet docker; then
    systemctl stop docker docker.socket || true
    systemctl disable docker docker.socket || true
fi

# 5. 配置 Podman 模拟 Docker API (1Panel 核心需求)
echo -e "${GREEN}配置 Podman API 服务以适配 1Panel...${NC}"

# 备份原有的 Docker Socket
if [ -S /var/run/docker.sock ]; then
    mv /var/run/docker.sock /var/run/docker.sock.bak.$(date +%s)
fi

# 启用并启动 podman.socket (提供 Docker API 兼容性)
systemctl enable --now podman.socket

# 建立软链接，确保 1Panel 能找到 Socket
ln -sf /run/podman/podman.sock /var/run/docker.sock

# 6. 迁移现有 Docker 镜像到 Podman (自动尝试)
echo -e "${YELLOW}是否尝试将现有 Docker 镜像迁移到 Podman? (y/n)${NC}"
read -r migrate_choice
if [[ "$migrate_choice" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}正在导出并重新导入镜像 (这可能需要较长时间)...${NC}"
    # 获取所有 Docker 镜像 ID
    IMAGES=$(/usr/bin/docker images -q 2>/dev/null || true)

    if [ -n "$IMAGES" ]; then
        for img in $IMAGES; do
            echo "迁移镜像: $img"
            /usr/bin/docker save "$img" | podman load || echo -e "${YELLOW}警告: 镜像 $img 迁移失败，跳过...${NC}"
        done
    else
        echo -e "${YELLOW}未检测到现有镜像或 docker 命令已不可用，跳过迁移。${NC}"
    fi
fi

# 7. 配置 Podman 容器自启动 (适配 1Panel 自动重启)
echo -e "${GREEN}配置容器自启动服务...${NC}"
systemctl enable --now podman-restart.service

# 8. 修正 1Panel 权限与路径
echo -e "${GREEN}优化 1Panel 兼容性...${NC}"
# 允许 Podman 绑定 1024 以下端口 (Root 模式通常不需要，但为了保险)
echo "net.ipv4.ip_unprivileged_port_start=0" > /etc/sysctl.d/podman-ports.conf
sysctl --system >/dev/null 2>&1

# 9. 询问并配置镜像加速器
echo -e "${YELLOW}是否配置 Podman 镜像加速器 (推荐国内服务器使用)? (y/n)${NC}"
read -r config_mirror
if [[ "$config_mirror" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}正在配置镜像加速...${NC}"
    
    # 创建配置目录（如果不存在）
    mkdir -p /etc/containers/

    # 写入镜像加速配置
    tee /etc/containers/registries.conf > /dev/null <<-'EOF'
unqualified-search-registries = ["docker.io", "quay.io"]

[[registry]]
prefix = "docker.io"
location = "docker.io"

# 这里可以替换为你搜集到的可用加速器地址
[[registry.mirror]]
location = "dockerpull.com"

[[registry.mirror]]
location = "docker.1panel.live"

[[registry.mirror]]
location = "mirror.baidubce.com"
EOF

    # 重启 Podman 服务使配置生效
    systemctl restart podman
    echo -e "${GREEN}镜像加速器配置完成！${NC}"
else
    echo -e "${GREEN}跳过镜像加速配置。${NC}"
fi

# 10. 验证安装
echo -e "${GREEN}>>> 验证安装结果:${NC}"
podman version | grep Version
if [ -S /var/run/docker.sock ]; then
    echo -e "${GREEN}Socket 链接状态: 正常 (/var/run/docker.sock 存在)${NC}"
else
    echo -e "${RED}Socket 链接状态: 异常 (找不到 /var/run/docker.sock)${NC}"
    exit 1
fi

echo -e "${YELLOW}-------------------------------------------------------${NC}"
echo -e "${GREEN}替换完成！${NC}"
echo -e "1. 请刷新 1Panel 面板，查看容器列表是否正常显示。"
echo -e "2. 原 Docker 软件建议保留一周，确认 1Panel 运行无误后再彻底卸载: apt purge docker-ce"
echo -e "${YELLOW}注意: Podman 默认存储路径为 /var/lib/containers，与 Docker 不同。${NC}"
echo -e "${YELLOW}-------------------------------------------------------${NC}"
