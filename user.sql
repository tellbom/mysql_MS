-- ================================================
-- 在MySQL主库上执行（会自动同步到从库）
-- ================================================

-- 1. VIP账户 - 关键业务用户
CREATE USER IF NOT EXISTS 'vip_user'@'%' IDENTIFIED BY 'VipPass@2024';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER ON *.* TO 'vip_user'@'%';

-- 2. 只读账户 - 仅查询权限
CREATE USER IF NOT EXISTS 'readonly_user'@'%' IDENTIFIED BY 'ReadOnly@2024';
GRANT SELECT ON *.* TO 'readonly_user'@'%';

-- 3. 普通账户 - 标准业务用户
CREATE USER IF NOT EXISTS 'normal_user'@'%' IDENTIFIED BY 'Normal@2024';
GRANT SELECT, INSERT, UPDATE, DELETE ON *.* TO 'normal_user'@'%';

-- 4. 监控账户 - ProxySQL健康检查专用
CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'Monitor@2024';
GRANT REPLICATION CLIENT, PROCESS ON *.* TO 'monitor'@'%';
-- 如果需要更详细的监控，可以添加：
-- GRANT SELECT ON performance_schema.* TO 'monitor'@'%';

-- 刷新权限
FLUSH PRIVILEGES;

-- 验证账户创建
SELECT User, Host, authentication_string FROM mysql.user 
WHERE User IN ('vip_user', 'readonly_user', 'normal_user', 'monitor');