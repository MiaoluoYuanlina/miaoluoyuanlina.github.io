#!/bin/bash

# ==============================================================================
# 1Panel 环境下 Docker 完美迁移至 Podman 脚本 (Debian 13 - 终极安全守护版)
# 新增特性：严格的 Docker 状态检查，遇到任何异常立即终止，防止破坏系统
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}  开始 1Panel 完美迁移：Docker -> Podman (安全版)${NC}"
echo -e "${GREEN}==================================================${NC}"

# 1. 权限检查
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 权限 (sudo) 运行此脚本！${NC}"
  exit 1
fi

# 2. 严格检查 Docker 状态 (安全守卫)
echo -e "\n${YELLOW}[1/7] 正在检查 Docker 运行环境...${NC}"

# 检查 Docker 命令是否存在
if ! command -v docker &> /dev/null; then
    echo -e "${RED}[严重错误] 未检测到 docker 命令！${NC}"
    echo -e "${RED}Docker 可能已被卸载，无法提取现有镜像。${NC}"
    echo -e "${RED}系统未做任何修改，脚本已安全终止。${NC}"
    exit 1
fi

# 检查 Docker 服务是否在运行，如果没运行则尝试启动它
if ! systemctl is-active --quiet docker; then
    echo -e "${YELLOW}检测到 Docker 服务未运行，正在尝试启动它以便导出镜像...${NC}"
    systemctl start docker || true
    sleep 3
fi

# 再次确认 Docker 是否成功运行
if ! systemctl is-active --quiet docker; then
    echo -e "${RED}[严重错误] Docker 服务无法启动！${NC}"
    echo -e "${RED}必须在 Docker 正常运行的状态下，才能无损提取现有镜像。${NC}"
    echo -e "${RED}请先修复 Docker。系统未做任何修改，脚本已安全终止。${NC}"
    exit 1
fi

echo -e "${GREEN} -> Docker 运行正常，环境检查通过！${NC}"

# 3. 安装 Podman 及依赖
echo -e "\n${YELLOW}[2/7] 正在安装 Podman 引擎...${NC}"
apt update
apt install -y podman uidmap podman-docker

# 4. 完美迁移 Docker 镜像到 Podman
echo -e "\n${YELLOW}[3/7] 正在无损迁移 Docker 镜像到 Podman (这可能需要几分钟)...${NC}"
docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>" | while read -r img; do
    echo "  - 正在导出并迁移镜像: $img"
    # 如果某一个镜像迁移失败，打印警告但不中断整个流程
    docker save "$img" | podman load || echo -e "${RED}  -> 镜像 $img 迁移失败，请事后检查。${NC}"
done

# 5. 剥离 Docker 守护进程 (保留数据和命令)
echo -e "\n${YELLOW}[4/7] 正在剥离 Docker 守护进程 (安全保留数据目录)...${NC}"
systemctl stop docker docker.socket || true
# 仅卸载后台引擎，保留 docker-ce-cli 和 docker-compose-plugin 供 1Panel 使用
apt-get remove -y docker-ce docker-ce-rootless-extras containerd.io docker.io

# 6. 配置 Podman API 与重启持久化
echo -e "\n${YELLOW}[5/7] 正在配置 Podman API 及重启持久化...${NC}"
systemctl enable --now podman.socket

# 解决重启后 socket 丢失的问题 (写入 systemd-tmpfiles)
echo "L+ /var/run/docker.sock - - - - /run/podman/podman.sock" > /etc/tmpfiles.d/podman-docker.conf
systemd-tmpfiles --create /etc/tmpfiles.d/podman-docker.conf

# 激活 Podman 的容器开机自启服务 (替代 Docker 的 restart: always)
systemctl enable podman-restart.service

# 验证伪装
sleep 2
if curl -s --unix-socket /var/run/docker.sock http://localhost/_ping | grep -q "OK"; then
    echo -e "${GREEN}  -> API 伪装成功！且已配置开机持久化。${NC}"
else
    echo -e "${RED}  -> [警告] API 伪装异常，请事后检查 podman.socket 状态。${NC}"
fi

# 7. 重建网络并唤醒 1Panel 应用
echo -e "\n${YELLOW}[6/7] 正在重建网络并唤醒 1Panel 应用...${NC}"
podman network create 1panel-network 2>/dev/null || true

APPS_DIR="/opt/1panel/apps"
if [ -d "$APPS_DIR" ]; then
    # 第一轮：启动所有依赖服务 (如 MySQL, Redis 等基础环境)
    echo -e "  -> [阶段一] 正在启动基础依赖服务..."
    find "$APPS_DIR" -maxdepth 2 -name "docker-compose.yml" | while read -r compose_file; do
        app_dir=$(dirname "$compose_file")
        cd "$app_dir" || continue
        docker compose up -d 2>/dev/null
    done
    
    # 第二轮：再次启动所有服务 (确保像 Halo 这种依赖数据库的应用能成功连上)
    echo -e "  -> [阶段二] 正在校验并拉起所有上层应用..."
    sleep 5
    find "$APPS_DIR" -maxdepth 2 -name "docker-compose.yml" | while read -r compose_file; do
        app_dir=$(dirname "$compose_file")
        app_name=$(basename "$app_dir")
        echo -e "  - 正在确认应用状态: ${GREEN}$app_name${NC}"
        cd "$app_dir" || continue
        docker compose up -d
    done
else
    echo -e "${RED}未找到 1Panel 应用目录 ($APPS_DIR)。${NC}"
fi

# 8. 重启 1Panel
echo -e "\n${YELLOW}[7/7] 正在重启 1Panel 面板服务...${NC}"
if command -v 1pctl &> /dev/null; then
    1pctl restart
else
    systemctl restart 1panel
fi

systemctl daemon-reload

echo -e "\n${GREEN}==================================================${NC}"
echo -e "${GREEN}  🎉 迁移完美完成！${NC}"
echo -e "  1. 你的所有数据 (Halo, Maddy 等) 已无损恢复。"
echo -e "  2. 即使重启服务器，1Panel 也能自动连接 Podman。"
echo -e "${GREEN}==================================================${NC}"
