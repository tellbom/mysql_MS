Below is a **single, self-contained Orchestrator operations guide** in Markdown.
– Everything comes from the steps we just walked through: Docker / single-node & Raft, MySQL side settings, ProxySQL interplay, automatic fail-over, recovery testing, day-2 tasks, and the most common “why没切主?” 故障排查。
– All file paths、ports、account names、passwords follow our demo；替换成你自己的即可。

---

# Orchestrator 3.x – 内网 Docker 部署 & 运维实战手册

| 章节                                                                       | 关键词                          |
| ------------------------------------------------------------------------ | ---------------------------- |
| [1. 架构概览](#1-架构概览)                                                       | 组件角色                         |
| [2. 镜像与目录](#2-镜像与目录)                                                     | pull / 目录规划                  |
| [3. MySQL 主从准备](#3-mysql-主从准备)                                           | my.cnf 样板 + 账号               |
| [4. 单节点 Orchestrator (SQLite)](#4-单节点-orchestrator-sqlite)               | 快速 POC                       |
| [5. 单节点 Orchestrator (MySQL Backend)](#5-单节点-orchestrator-mysql-backend) | 生产推荐                         |
| [6. Raft 高可用 (3-节点)](#6-raft-高可用-3-节点)                                   | 可选                           |
| [7. ProxySQL 联动](#7-proxysql-联动)                                         | hostgroups / 切主流             |
| [8. 自动恢复 & 灾演](#8-自动恢复--灾演)                                              | RecoverMasterCluster / 测试    |
| [9. 日常运维命令](#9-日常运维命令)                                                   | discover / relocate / forget |
| [10. 故障排查指南](#10-故障排查指南)                                                 | 9001 / split-brain / DNS     |
| [11. 配置清单](#11-配置清单)                                                     | 所有文件一览                       |

---

## 1. 架构概览

```
┌──────────┐   tcp 3307/3308      ┌──────────────┐   tcp 6033
│  MySQL M │◄────────────────────►│   ProxySQL   │◄────────┐
└──────────┘                      └──────────────┘         │
    ▲              HTTP 3000 / API 10008                   ▼
    │                                                    应用
    │
┌──────────┐
│  Orchestr│  (单节点 or Raft 3 节点，负责探测 / 提升 / 降级)
└──────────┘
```

---

## 2. 镜像与目录

```bash
# 镜像
docker pull percona/percona-orchestrator:3.2.6        # amd64
# 或 openarkcode/orchestrator:3.2.6                   # arm64 / multi-arch

# 目录
/opt/orchestrator/
├── conf/                 # orchestrator.conf.json + orc-topology.cnf
└── data/                 # SQLite / Raft 持久化
```

---

## 3. MySQL 主从准备

<details>
<summary><strong>主库 my.cnf（摘要）</strong></summary>

```ini
[mysqld]
server-id = 1
gtid_mode = ON
enforce_gtid_consistency = ON
log_bin   = mysql-bin
log_slave_updates = ON
read_only = OFF
super_read_only = OFF
report_host = 192.168.48.128
report_port = 3307
```

</details>

<details>
<summary><strong>从库 my.cnf（摘要）</strong></summary>

```ini
[mysqld]
server-id = 2
log_slave_updates = ON
read_only = ON
super_read_only = ON
report_host = 192.168.48.128
report_port = 3308
```

</details>

### 公用账号

```sql
-- 复制
CREATE USER 'repl'@'%' IDENTIFIED BY 'ReplPwd123!'; GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';

-- Orchestrator
CREATE USER 'orchestrator'@'%' IDENTIFIED BY 'orcpass';
GRANT SUPER,PROCESS,RELOAD,REPLICATION SLAVE,SHOW VIEW ON *.* TO 'orchestrator'@'%';

-- ProxySQL 探针
CREATE USER 'monitor'@'%' IDENTIFIED BY 'Mon1torPwd!'; GRANT USAGE ON *.* TO 'monitor'@'%';

-- 业务
CREATE USER 'app_rw'@'%' IDENTIFIED BY 'AppRWPwd!';
GRANT INSERT,UPDATE,DELETE,SELECT ON test1.* TO 'app_rw'@'%';
CREATE USER 'app_ro'@'%' IDENTIFIED BY 'AppROPwd!';
GRANT SELECT ON test1.* TO 'app_ro'@'%';
```

---

## 4. 单节点 Orchestrator (SQLite)

```bash
cat >/opt/orchestrator/conf/orchestrator.conf.json <<'EOF'
{
  "Debug": false,
  "ListenAddress": ":3000",
  "BackendDB": "sqlite",
  "SQLite3DataFile": "/var/lib/orchestrator/orchestrator.db",
  "MySQLTopologyUser": "orchestrator",
  "MySQLTopologyPassword": "orcpass",
  "HostnameResolveMethod": "none",
  "RecoverMasterCluster": true,
  "RaftEnabled": false
}
EOF
cat >/opt/orchestrator/conf/orc-topology.cnf <<'EOF'
[client]
user=orchestrator
password=orcpass
EOF
chmod 600 /opt/orchestrator/conf/orc-topology.cnf

docker run -d --name orchestrator \
  -p 3000:3000 \
  -v /opt/orchestrator/conf:/etc/orchestrator \
  -v /opt/orchestrator/data:/var/lib/orchestrator \
  percona/percona-orchestrator:3.2.6
```

---

## 5. 单节点 Orchestrator (MySQL Backend)

```bash
# BackendDB on 3309
docker run -d --name orchestrator-meta -p 3309:3306 \
  -e MYSQL_ROOT_PASSWORD=meta123 \
  -v /opt/orchestrator/meta:/var/lib/mysql mysql:5.7

# 库 & 账号
mysql -uroot -pmeta123 -h127.0.0.1 -P3309 <<SQL
CREATE DATABASE orchestrator;
CREATE USER 'orc_meta'@'%' IDENTIFIED BY 'orcmetapass';
GRANT ALL ON orchestrator.* TO 'orc_meta'@'%';
SQL
```

`orchestrator.conf.json` 关键差异：

```json
"BackendDB": "mysql",
"MySQLOrchestratorHost": "192.168.48.128",
"MySQLOrchestratorPort": 3309,
"MySQLOrchestratorDatabase": "orchestrator",
"MySQLOrchestratorUser": "orc_meta",
"MySQLOrchestratorPassword": "orcmetapass",
"RaftEnabled": false
```

其余启动同上。

---

## 6. （可选）Raft 3-节点 HA

* 每台都相同镜像 + 同一 BackendDB（或各自 SQLite）
* 配置统一：

```json
"RaftEnabled": true,
"RaftPort": 10008,
"RaftBind": "0.0.0.0",
"RaftAdvertise": "<每台自身 IP>",
"RaftDataDir": "/var/lib/orchestrator",
"RaftNodes": [
  "10.0.0.11:10008",
  "10.0.0.12:10008",
  "10.0.0.13:10008"
]
```

* Docker 需 `-p 10008:10008`。
* 节点 > (N/2)+1 在线即可完成选主。

---

## 7. ProxySQL 联动

```sql
/* 6032 */
INSERT INTO mysql_servers(hostgroup_id,hostname,port) VALUES
 (10,'192.168.48.128',3307),
 (20,'192.168.48.128',3308);

INSERT INTO mysql_replication_hostgroups(writer_hostgroup,reader_hostgroup)
 VALUES(10,20);

SET mysql-monitor_username='monitor';
SET mysql-monitor_password='Mon1torPwd!';

INSERT INTO mysql_users(username,password,default_hostgroup,active) VALUES
 ('app_rw','AppRWPwd!',10,1),
 ('app_ro','AppROPwd!',20,1);

LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;
LOAD MYSQL USERS   TO RUNTIME; SAVE MYSQL USERS   TO DISK;
```

探针检测逻辑：`read_only=0 && Slave_SQL_Running='No'` ⇒ Writer。
切主后 Orchestrator 令 3308 `read_only=0`；ProxySQL 下一次心跳即把写组指到 3308。

---

## 8. 自动恢复 & 灾演

* 关键开关：`RecoverMasterCluster=true`
* 运行时确保 `enable-global-recoveries`

```bash
docker exec orchestrator orchestrator-client -c enable-global-recoveries
```

**演练步骤**

1. `docker stop mysql-master`
2. `tail -f docker logs orchestrator` → see *promoted 3308*
3. 应用再写 `6033` 无中断
4. `docker start mysql-master` → 自动只读、加入 Reader 组

---

## 9. 日常运维命令

```bash
# 发现新实例
orchestrator-client -c discover -i 192.168.48.128:3309

# 查看拓扑
orchestrator-client -c topology -i 192.168.48.128:3307

# 手动换主
orchestrator-client -c relocate -i 192.168.48.128:3308 -d 192.168.48.128:3307

# 忘记实例
orchestrator-client -c forget -i e9cc5c0ade99:3307
```

---

## 10. 故障排查指南

| 症状                                         | 重点排查                                                                   |
| ------------------------------------------ | ---------------------------------------------------------------------- |
| `Max connect timeout reached hostgroup 10` | `runtime_mysql_servers` Writer OFFLINE；Orchestrator没晋升或读写变量没切          |
| `dial tcp lookup <hostname> no such host`  | `HostnameResolveMethod=none` 或 /etc/hosts 映射                           |
| Split-brain（双写）                            | 确认旧主 `my.cnf` 固化 `read_only=ON`；ProxySQL Writer 只 1 台                  |
| 自动恢复无效                                     | `RecoverMasterCluster`=false / 未 `enable-global-recoveries` / api 权限不足 |

---

## 11. 文件清单

```
/opt/orchestrator/
├── conf/
│   ├── orchestrator.conf.json
│   └── orc-topology.cnf          # [client] user+pwd
└── data/                         # SQLite / Raft snapshot
/root/mysql/master/conf/50-base.cnf
/root/mysql/slave/conf/50-base.cnf
/root/proxysql.cnf               # (如使用文件方式编排 ProxySQL)
```

---

### 结束语

阅读完这份指南，你就拥有：

* **Docker-only** 的 MySQL-GTID 主从
* 单节点 Orchestrator（可升级 Raft）全自动故障切换
* ProxySQL 3.x 连接池 + 读写分离 + 跟随切主
* 完整日常脚本、常见坑排查

把其中的 **IP / 端口 / 密码** 改为生产值即可落地。
随时需要更多细节（半同步、binlog server、多层复制、TLS、监控接 Prometheus…）再 @ 我！
