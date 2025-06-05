#!/bin/bash
# ================================================
# ProxySQL 配置脚本 - 在容器内执行
# 执行方式：
# 1. docker exec -it proxysql-server /bin/bash
# 2. 将此脚本内容保存为 configure_proxysql.sh
# 3. chmod +x configure_proxysql.sh && ./configure_proxysql.sh
# ================================================

# MySQL服务器配置（请根据实际情况修改）
MASTER_HOST="192.168.48.128"
SLAVE1_HOST="192.168.48.128" 
MASTER_PORT=3307
SLAVE1_PORT=3308

echo "==> 开始配置ProxySQL..."

# 连接到ProxySQL管理接口
mysql -h127.0.0.1 -P6032 -uadmin -padmin <<EOF

-- ================================================
-- 1. 清理现有配置
-- ================================================
DELETE FROM mysql_replication_hostgroups;  -- 先删除这个，避免外键约束
DELETE FROM mysql_servers;
DELETE FROM mysql_users;
DELETE FROM mysql_query_rules;

-- ================================================
-- 2. 添加MySQL服务器
-- ================================================
-- 写组（hostgroup 10）：主库
INSERT INTO mysql_servers(hostgroup_id, hostname, port, weight, max_connections, comment) VALUES
(10, '${MASTER_HOST}', ${MASTER_PORT}, 1000, 1000, 'Master - Write Group');

-- 读组（hostgroup 20）：从库
INSERT INTO mysql_servers(hostgroup_id, hostname, port, weight, max_connections, comment) VALUES
(20, '${SLAVE1_HOST}', ${SLAVE1_PORT}, 900, 1000, 'Slave1 - Read Group');


-- ================================================
-- 3. 配置主从复制组
-- ================================================
-- 先删除可能存在的旧配置
DELETE FROM mysql_replication_hostgroups WHERE writer_hostgroup IN (10);

INSERT INTO mysql_replication_hostgroups 
(writer_hostgroup, reader_hostgroup, check_type, comment) VALUES
(10, 20, 'read_only', 'Standard Read/Write Split');

-- 注意：一个writer_hostgroup只能对应一个reader_hostgroup
-- 所以VIP用户直接通过查询规则强制走hostgroup 10即可

-- ================================================
-- 4. 添加用户账户
-- ================================================
-- VIP用户：读写都走主库
INSERT INTO mysql_users 
(username, password, default_hostgroup, transaction_persistent, max_connections, comment) VALUES
('vip_user', 'VipPass@2024', 10, 1, 200, 'VIP用户-读写都走主库');

-- 只读用户：只能读从库
INSERT INTO mysql_users 
(username, password, default_hostgroup, transaction_persistent, max_connections, comment) VALUES
('readonly_user', 'ReadOnly@2024', 20, 0, 500, '只读用户-禁止写操作');

-- 普通用户：读从写主
INSERT INTO mysql_users 
(username, password, default_hostgroup, transaction_persistent, max_connections, comment) VALUES
('normal_user', 'Normal@2024', 10, 1, 1000, '普通用户-读从写主');

-- ================================================
-- 5. 配置查询规则
-- ================================================
-- VIP用户规则：所有查询都走主库
INSERT INTO mysql_query_rules 
(rule_id, active, username, destination_hostgroup, apply, comment) VALUES
(100, 1, 'vip_user', 10, 1, 'VIP用户所有操作都走主库');

-- 只读用户规则：禁止写操作
INSERT INTO mysql_query_rules 
(rule_id, active, username, match_pattern, error_msg, apply, comment) VALUES
(200, 1, 'readonly_user', '^(INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|TRUNCATE|REPLACE|LOCK|UNLOCK|GRANT|REVOKE)', 
 'ERROR: Write operations are not allowed for readonly user', 1, '只读用户禁止写操作');

-- 只读用户规则：SELECT走从库
INSERT INTO mysql_query_rules 
(rule_id, active, username, match_pattern, destination_hostgroup, apply, comment) VALUES
(201, 1, 'readonly_user', '^SELECT.*', 20, 1, '只读用户查询走从库');

-- 普通用户规则：SELECT FOR UPDATE走主库
INSERT INTO mysql_query_rules 
(rule_id, active, username, match_pattern, destination_hostgroup, apply, comment) VALUES
(300, 1, 'normal_user', '^SELECT.*FOR\s+UPDATE', 10, 1, '普通用户SELECT FOR UPDATE走主库');

-- 普通用户规则：普通SELECT走从库
INSERT INTO mysql_query_rules 
(rule_id, active, username, match_pattern, destination_hostgroup, apply, comment) VALUES
(301, 1, 'normal_user', '^SELECT', 20, 1, '普通用户普通SELECT走从库');

-- 事务规则：确保事务一致性
INSERT INTO mysql_query_rules 
(rule_id, active, match_pattern, destination_hostgroup, apply, comment) VALUES
(400, 1, '^BEGIN|^START\s+TRANSACTION', 10, 1, '事务开始走主库');

-- 特殊查询规则
INSERT INTO mysql_query_rules 
(rule_id, active, match_pattern, destination_hostgroup, apply, comment) VALUES
(500, 1, 'LAST_INSERT_ID', 10, 1, 'LAST_INSERT_ID走主库'),
(501, 1, '@@(IDENTITY|last_insert_id)', 10, 1, '系统变量查询走主库'),
(502, 1, 'FOUND_ROWS', 10, 1, 'FOUND_ROWS走主库');

-- 强制主库标记
INSERT INTO mysql_query_rules 
(rule_id, active, match_pattern, destination_hostgroup, apply, comment) VALUES
(600, 1, '.*FORCE_MASTER.*', 10, 1, '带FORCE_MASTER注释的查询走主库');

-- ================================================
-- 6. 配置监控
-- ================================================
-- 设置监控用户
UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_username';
UPDATE global_variables SET variable_value='Monitor@2024' WHERE variable_name='mysql-monitor_password';

-- 监控间隔设置
UPDATE global_variables SET variable_value='2000' WHERE variable_name='mysql-monitor_connect_interval';
UPDATE global_variables SET variable_value='2000' WHERE variable_name='mysql-monitor_ping_interval';
UPDATE global_variables SET variable_value='2000' WHERE variable_name='mysql-monitor_read_only_interval';
UPDATE global_variables SET variable_value='1000' WHERE variable_name='mysql-monitor_replication_lag_interval';

-- 设置最大复制延迟（秒）
UPDATE mysql_servers SET max_replication_lag=3 WHERE hostgroup_id=20;

-- ================================================
-- 7. 应用配置
-- ================================================
LOAD MYSQL SERVERS TO RUNTIME;
LOAD MYSQL USERS TO RUNTIME;
LOAD MYSQL QUERY RULES TO RUNTIME;
LOAD MYSQL VARIABLES TO RUNTIME;

SAVE MYSQL SERVERS TO DISK;
SAVE MYSQL USERS TO DISK;
SAVE MYSQL QUERY RULES TO DISK;
SAVE MYSQL VARIABLES TO DISK;

-- ================================================
-- 8. 查看配置结果
-- ================================================
SELECT '=== MySQL Servers ===' AS '';
SELECT hostgroup_id, hostname, port, status, weight, comment FROM mysql_servers ORDER BY hostgroup_id;

SELECT '=== MySQL Users ===' AS '';
SELECT username, default_hostgroup, transaction_persistent, max_connections, comment FROM mysql_users;

SELECT '=== Query Rules ===' AS '';
SELECT rule_id, username, match_pattern, destination_hostgroup, apply, comment FROM mysql_query_rules ORDER BY rule_id;

SELECT '=== Replication Hostgroups ===' AS '';
SELECT * FROM mysql_replication_hostgroups;

EOF

echo ""
echo "==> ProxySQL配置完成！"
echo ""
echo "测试连接命令："
echo "# VIP用户测试"
echo "mysql -h<宿主机IP> -P6033 -uvip_user -pVipPass@2024 -e 'SELECT @@hostname'"
echo ""
echo "# 只读用户测试"
echo "mysql -h<宿主机IP> -P6033 -ureadonly_user -pReadOnly@2024 -e 'SELECT @@hostname'"
echo ""
echo "# 普通用户测试"
echo "mysql -h<宿主机IP> -P6033 -unormal_user -pNormal@2024 -e 'SELECT @@hostname'"