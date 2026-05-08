#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 错误处理函数：遇到错误暂停并等待人工干预
pause_on_error() {
    if [ $? -ne 0 ]; then
        echo -e "\n${RED}[ERROR] 脚本在执行上一条命令时出错。${NC}"
        echo -e "${YELLOW}请检查错误信息。修复后按 [Enter] 继续，或按 [Ctrl+C] 退出。${NC}"
        read
    fi
}

echo -e "${YELLOW}>>> 准备从 Podman 迁移到 Docker (Debian 13 / 1Panel 专用) <<<${NC}"

# 1. 权限检查
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请以 root 权限运行此脚本 (sudo -i)${NC}"
  exit 1
fi

# 2. 导出 Podman 镜像
echo -e "${GREEN}[1/7] 正在备份 Podman 镜像...${NC}"
BACKUP_DIR="/tmp/podman_migration_$(date +%s)"
mkdir -p "$BACKUP_DIR"
# 获取镜像列表，排除中间层镜像
IMAGE_LIST=$(podman images --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>")

if [ -z "$IMAGE_LIST" ]; then
    echo "未发现需要迁移的镜像。"
else
    for img in $IMAGE_LIST; do
        safe_name=$(echo $img | tr ':/' '_')
        echo "导出中: $img"
        podman save -o "$BACKUP_DIR/${safe_name}.tar" "$img"
        pause_on_error
    done
fi

# 3. 停止并清理 Podman
echo -e "${GREEN}[2/7] 停止 Podman 容器并清理环境...${NC}"
podman stop -a >/dev/null 2>&1
podman rm -a >/dev/null 2>&1
# 停止 podman.socket 防止占用
systemctl stop podman.socket podman.service 2>/dev/null
pause_on_error

# 4. 卸载 Podman 相关包
echo -e "${GREEN}[3/7] 卸载 Podman 软件包...${NC}"
apt-get remove -y podman buildah skopeo python3-podman
apt-get autoremove -y
pause_on_error

# 5. 安装 Docker Engine (处理 Debian 13 兼容性)
echo -e "${GREEN}[4/7] 配置 Docker 官方源...${NC}"
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
chmod a+r /etc/apt/keyrings/docker.gpg

# 由于 Debian 13 较新，如果 trixie 源不存在，则回退使用 bookworm 源
VERSION_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
[ "$VERSION_CODENAME" == "trixie" ] && REPO_CODENAME="bookworm" || REPO_CODENAME=$VERSION_CODENAME

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $REPO_CODENAME stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

echo -e "${GREEN}[5/7] 安装 Docker 核心组件...${NC}"
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
pause_on_error

systemctl enable --now docker
echo -e "${GREEN}Docker 服务已启动${NC}"

# 6. 导入镜像到 Docker
echo -e "${GREEN}[6/7] 正在将镜像导入 Docker...${NC}"
if [ -d "$BACKUP_DIR" ]; then
    for tar_file in "$BACKUP_DIR"/*.tar; do
        if [ -f "$tar_file" ]; then
            echo "导入中: $tar_file"
            docker load -i "$tar_file"
            pause_on_error
        fi
    done
fi

# 7. 清理临时文件
rm -rf "$BACKUP_DIR"

# 8. 1Panel 适配指导
echo -e "\n${YELLOW}==================================================${NC}"
echo -e "${GREEN}迁移完成！请执行以下操作适配 1Panel：${NC}"
echo -e "${YELLOW}1. 检查 Socket：${NC} 确保 /var/run/docker.sock 存在"
echo -e "   命令: ls -l /var/run/docker.sock"
echo -e "${YELLOW}2. 修改 1Panel 面板设置：${NC}"
echo -e "   登录 1Panel -> [容器] -> [设置] -> [基础设置]"
echo -e "   确认端点地址为: ${NC}unix:///var/run/docker.sock"
echo -e "${YELLOW}3. 重建容器：${NC}"
echo -e "   在 1Panel [容器] 列表中，由于 Podman 容器已消失，"
echo -e "   你需要点击“创建容器”，选择刚才导入的镜像，"
echo -e "   并挂载原有的数据目录（通常在 /opt/1panel/apps/...）。"
echo -e "${YELLOW}==================================================${NC}"
