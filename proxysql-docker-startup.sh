#!/bin/bash
# ================================================
# ProxySQL Docker 启动脚本
# ================================================

# 配置变量
PROXYSQL_NAME="proxysql-server"
PROXYSQL_VERSION="3.0.1"
PROXYSQL_ADMIN_PORT=6032
PROXYSQL_MYSQL_PORT=6033
PROXYSQL_ADMIN_USER="admin"
PROXYSQL_ADMIN_PASS="admin"


# 1. 停止并删除旧容器（如果存在）
echo "==> 清理旧容器..."
docker stop ${PROXYSQL_NAME} 2>/dev/null
docker rm ${PROXYSQL_NAME} 2>/dev/null

# 2. 创建数据目录
echo "==> 创建数据目录..."
mkdir -p /root/proxysql/data
mkdir -p /root/proxysql/logs

# 3. 启动ProxySQL容器
echo "==> 启动ProxySQL容器..."
docker run -d \
  --name ${PROXYSQL_NAME} \
  --restart=always \
  -p ${PROXYSQL_ADMIN_PORT}:6032 \
  -p ${PROXYSQL_MYSQL_PORT}:6033 \
  -v /root/proxysql/data:/var/lib/proxysql \
  -v /root/proxysql/logs:/var/log/proxysql \
  proxysql/proxysql:${PROXYSQL_VERSION}

# 4. 等待容器启动
echo "==> 等待ProxySQL启动..."
sleep 5

# 5. 检查容器状态
if ! docker ps | grep -q ${PROXYSQL_NAME}; then
    echo "错误：ProxySQL容器启动失败!"
    docker logs ${PROXYSQL_NAME}
    exit 1
fi

echo "==> ProxySQL容器启动成功!"
echo ""
echo "容器信息："
echo "- 容器名称: ${PROXYSQL_NAME}"
echo "- 管理端口: ${PROXYSQL_ADMIN_PORT} (admin/admin)"
echo "- MySQL端口: ${PROXYSQL_MYSQL_PORT}"
echo ""
echo "==> 现在可以进入容器配置ProxySQL："
echo "docker exec -it ${PROXYSQL_NAME} /bin/bash"
echo ""
echo "==> 或直接执行配置："
echo "docker exec -it ${PROXYSQL_NAME} mysql -h127.0.0.1 -P6032 -uadmin -padmin"