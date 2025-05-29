以下文档将完整复盘我们 **测试环境（Docker 方式）** 从零到有的全部脚本与关键注意事项，格式为 **Markdown**，方便你直接复制到内网 Wiki 或 README。

> ‼️ **默认前提**
>
> * 操作系统：CentOS 7/8（任何能跑 Docker ≥20.10 即可）
> * MySQL 版本：官方镜像 `mysql:5.7.40`
> * ProxySQL 版本：`proxysql/proxysql:3.0.1`
> * 网络：所有容器都在同一宿主机 Bridge 网络，彼此通过 **宿主 IP + 暴露端口** 通信
> * 内网无外网 DNS；镜像需提前离线导入

---

# 目录

1. [目录结构 & 挂载点](#目录结构--挂载点)
2. [MySQL 主从部署](#mysql-主从部署)
   2.1 [准备配置文件](#21-准备配置文件)
   2.2 [启动主库 (master)](#22-启动主库-master)
   2.3 [创建复制账号](#23-创建复制账号)
   2.4 [全量导出并导入从库](#24-全量导出并导入从库)
   2.5 [启动从库 (slave) 并开启复制](#25-启动从库-slave-并开启复制)
   2.6 [开启只读保护](#26-开启只读保护)
3. [ProxySQL 安装与配置](#proxysql-安装与配置)
   3.1 [准备 `proxysql.cnf`](#31-准备-proxysqlcnf)
   3.2 [运行容器](#32-运行容器)
   3.3 [后端节点登记 & 读写分离规则](#33-后端节点登记--读写分离规则)
4. [后端 MySQL 账号与权限](#后端-mysql-账号与权限)
5. [常用维护脚本](#常用维护脚本)
6. [故障处理 — 跳过单条 GTID 事务](#故障处理--跳过单条-gtid-事务)
7. [常见坑 & 注意事项](#常见坑--注意事项)

---

## 目录结构 & 挂载点

```bash
# 建议固定在 /data 或 /root 下
# ── mysql
#    ├── master
#    │   ├── conf/my.cnf
#    │   └── data/                    # 数据卷
#    └── slave
#        ├── conf/my.cnf
#        └── data/
# ── proxysql
#     └── proxysql.cnf
mkdir -p /root/mysql/{master,slave}/{conf,data}
mkdir -p /root/proxysql
```

---

## MySQL 主从部署

### 2.1 准备配置文件

**`/root/mysql/master/conf/my.cnf`**

```ini
[mysqld]
server-id               = 1
log_bin                 = mysql-bin           # 开启 binlog
gtid_mode               = ON
enforce_gtid_consistency= ON
innodb_buffer_pool_size = 1G                  # 根据宿主机内存调整
```

**`/root/mysql/slave/conf/my.cnf`**

```ini
[mysqld]
server-id               = 2
read_only               = ON
super_read_only         = ON
relay_log_recovery      = ON
gtid_mode               = ON
enforce_gtid_consistency= ON
```

---

### 2.2 启动主库 (master)

```bash
docker run -d --name mysql-master \
  -p 3307:3306 \
  -e MYSQL_ROOT_PASSWORD=123456 \
  -e TZ=Asia/Shanghai \
  -v /root/mysql/master/conf:/etc/mysql/conf.d:ro \
  -v /root/mysql/master/data:/var/lib/mysql \
  --restart unless-stopped \
  mysql:5.7.40
```

---

### 2.3 创建复制账号

```bash
docker exec -it mysql-master mysql -uroot -p123456 -e "
CREATE USER 'repl'@'%' IDENTIFIED BY 'ReplPwd123!';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;"
```

---

### 2.4 全量导出并导入从库

```bash
# 导出（主库→宿主 /root/full.sql）
docker exec mysql-master \
  sh -c "mysqldump -uroot -p123456 --single-transaction --set-gtid-purged=ON --all-databases" \
  > /root/full.sql
```

---

### 2.5 启动从库 (slave) 并开启复制

```bash
docker run -d --name mysql-slave \
  -p 3308:3306 \
  -e MYSQL_ROOT_PASSWORD=123456 \
  -e TZ=Asia/Shanghai \
  -v /root/mysql/slave/conf:/etc/mysql/conf.d:ro \
  -v /root/mysql/slave/data:/var/lib/mysql \
  --restart unless-stopped \
  mysql:5.7.40

# 导入 dump
docker exec -i mysql-slave mysql -uroot -p123456 < /root/full.sql

# 指向主库并开启复制（GTID 自动定位）
docker exec -it mysql-slave mysql -uroot -p123456 -e "
CHANGE MASTER TO
  MASTER_HOST='192.168.48.128',
  MASTER_PORT=3307,
  MASTER_USER='repl',
  MASTER_PASSWORD='ReplPwd123!',
  MASTER_AUTO_POSITION=1;
START SLAVE;"
```

> **检查**
>
> ```sql
> SHOW SLAVE STATUS\G      -- Slave_IO/Slave_SQL 都应为 Yes
> ```

---

### 2.6 开启只读保护

```sql
-- 在从库执行
SET GLOBAL read_only=1;
SET GLOBAL super_read_only=1;
```

(已写入 `my.cnf` 会长期生效)

---

## ProxySQL 安装与配置

### 3.1 准备 `proxysql.cnf`

```ini
datadir="/var/lib/proxysql"

admin_variables=
{
  admin_credentials="admin:admin"
  mysql_ifaces="0.0.0.0:6032"
}

mysql_variables=
{
  threads=4
  interfaces="0.0.0.0:6033"
  max_connections=20000
}
```

保存到 `/root/proxysql/proxysql.cnf`.

---

### 3.2 运行容器

```bash
docker run -d --name proxysql \
  -p 6032:6032 -p 6033:6033 \
  -v /root/proxysql/proxysql.cnf:/etc/proxysql.cnf \
  --restart unless-stopped \
  proxysql/proxysql:3.0.1
```

---

### 3.3 后端节点登记 & 读写分离规则

```bash
# 登录 6032
docker exec -it proxysql mysql -uadmin -padmin -h127.0.0.1 -P6032
```

```sql
/* 1. 后端 MySQL 节点 */
DELETE FROM mysql_servers;   -- 首次可省
INSERT INTO mysql_servers(hostgroup_id,hostname,port,comment) VALUES
  (10,'192.168.48.128',3307,'master-writer'),
  (20,'192.168.48.128',3308,'slave-reader');

/* 2. 监控账号 */
SET mysql-monitor_username='monitor';
SET mysql-monitor_password='Mon1torPwd!';

/* 3. Writer/Reader 绑定 */
INSERT IGNORE INTO mysql_replication_hostgroups(writer_hostgroup,reader_hostgroup,comment)
  VALUES (10,20,'master-slave');

/* 4. 前端业务账号 */
INSERT INTO mysql_users(username,password,default_hostgroup,active,comment) VALUES
  ('app_rw','AppRWPwd!',10,1,'rw clients'),
  ('app_ro','AppROPwd!',20,1,'ro clients');

/* 5. Query Rule：rw 账号的 SELECT 走读库 */
DELETE FROM mysql_query_rules;
INSERT INTO mysql_query_rules(rule_id,username,match_digest,destination_hostgroup,apply)
  VALUES (1,'app_rw','^SELECT',20,1);

/* 6. 生效 & 持久 */
LOAD MYSQL SERVERS TO RUNTIME;        SAVE MYSQL SERVERS TO DISK;
LOAD MYSQL USERS   TO RUNTIME;        SAVE MYSQL USERS   TO DISK;
LOAD MYSQL QUERY RULES TO RUNTIME;    SAVE MYSQL QUERY RULES TO DISK;
```

---

## 后端 MySQL 账号与权限

在 **主库 + 从库** 都执行：

```sql
-- 监控
CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED WITH mysql_native_password BY 'Mon1torPwd!';
GRANT USAGE ON *.* TO 'monitor'@'%';

-- 读写业务
CREATE USER IF NOT EXISTS 'app_rw'@'%' IDENTIFIED WITH mysql_native_password BY 'AppRWPwd!';
GRANT ALL PRIVILEGES ON test1.* TO 'app_rw'@'%';
GRANT ALL PRIVILEGES ON test2.* TO 'app_rw'@'%';

-- 只读业务
CREATE USER IF NOT EXISTS 'app_ro'@'%' IDENTIFIED WITH mysql_native_password BY 'AppROPwd!';
GRANT SELECT, SHOW VIEW ON test1.* TO 'app_ro'@'%';
GRANT SELECT, SHOW VIEW ON test2.* TO 'app_ro'@'%';

FLUSH PRIVILEGES;
```

---

## 常用维护脚本

| 任务        | 命令                                                                                                                      |
| --------- | ----------------------------------------------------------------------------------------------------------------------- |
| 查看运行时后端状态 | `SELECT hostgroup_id,hostname,port,status FROM runtime_mysql_servers;`                                                  |
| 上线节点      | `UPDATE mysql_servers SET status='ONLINE' WHERE hostname='x.x.x.x'; LOAD MYSQL SERVERS TO RUNTIME;`                     |
| 新增从库      | `INSERT INTO mysql_servers(hostgroup_id,hostname,port) VALUES (20,'NEW_IP',3306); LOAD MYSQL SERVERS TO RUNTIME; SAVE…` |
| 在线修改密码    | 更新 `mysql_users.password` → `LOAD MYSQL USERS TO RUNTIME; SAVE…`                                                        |

---

## 故障处理 — 跳过单条 GTID 事务

```sql
-- 从库：定位差异
SHOW SLAVE STATUS\G
-- 假设 Retrieved = …:9-17  Executed = …:1-15  → 要跳 16
STOP SLAVE SQL_THREAD;
SET GLOBAL super_read_only=0;  -- 临时解除只读
SET SESSION gtid_next='UUID:16';
BEGIN; COMMIT;
SET SESSION gtid_next='AUTOMATIC';
SET GLOBAL super_read_only=1;
START SLAVE SQL_THREAD;
```

---

## 常见坑 & 注意事项

| 场景                                                  | 处理                                                            |
| --------------------------------------------------- | ------------------------------------------------------------- |
| `ERROR 9001 Max connect timeout`                    | 运行时没有 ONLINE Writer；重新 `LOAD MYSQL SERVERS…` 或把节点设 `ONLINE`   |
| `1524 Plugin 'mysql_native_password' is not loaded` | 确保账号 `IDENTIFIED WITH mysql_native_password`，并在 ProxySQL 同步密码 |
| ProxySQL 重启后配置丢失                                    | 每次改完 **必须** `SAVE … TO DISK`                                  |
| 忘记 `super_read_only`                                | 从库可被误写，导致复制断；务必在 `my.cnf` 固化 `super_read_only=ON`             |
| Navicat 不能连                                         | 确认端口 **6033**、账号密码、ProxySQL `mysql_users` 已 `LOAD`            |

---

> 至此，一套 **主从 GTID + ProxySQL 读写分离** 的内网 Docker 测试环境即全部脚本梳理完毕。
> 如需灰度扩大（新增从库）、做压力测试、或者引入 Orchestrator 自动切主，只要在此基础上增量配置即可。祝部署顺利!
