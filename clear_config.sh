#!/bin/bash
# ================================================
# ProxySQL 配置修复脚本
# 先清理所有配置，再重新配置
# ================================================

echo "==> 清理ProxySQL所有配置..."

# 连接到ProxySQL管理接口并清理
docker exec -i proxysql-server mysql -h127.0.0.1 -P6032 -uadmin -padmin <<'EOF'
-- 清理所有配置
DELETE FROM mysql_replication_hostgroups;
DELETE FROM mysql_query_rules;
DELETE FROM mysql_users;
DELETE FROM mysql_servers;

-- 应用清理
LOAD MYSQL SERVERS TO RUNTIME;
LOAD MYSQL USERS TO RUNTIME;
LOAD MYSQL QUERY RULES TO RUNTIME;
LOAD MYSQL VARIABLES TO RUNTIME;

-- 保存清理结果
SAVE MYSQL SERVERS TO DISK;
SAVE MYSQL USERS TO DISK;
SAVE MYSQL QUERY RULES TO DISK;
SAVE MYSQL VARIABLES TO DISK;

SELECT 'All configurations cleared!' AS Status;
EOF

echo ""
echo "==> 清理完成，现在可以重新运行配置脚本"
echo "chmod +x configure_proxysql.sh && ./configure_proxysql.sh"