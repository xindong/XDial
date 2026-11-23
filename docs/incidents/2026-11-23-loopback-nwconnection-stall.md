# 突发连接让 Provider 的回环 NWConnection 卡死，整机断网

## 现场与边界

时间为本机 NZDT，取自系统统一日志。Debug 已连接约 2 小时 18 分（事务 1AEF41A9），
用户在 19:16:18 从菜单栏手动断开后网络恢复。

看到的：
- 19:15:55：约 1 s 内 Provider 收到 148 个新流量，其中 142 个是同一应用连向
  `api.github.com:443` 的 TCP；同时 Tailscale 扩展向 8 个公共解析器并发 DNS（UDP 与
  TCP 各数十个，随后不断重试）。
- 19:15:56 有 161 个到 sing-box SOCKS 入口（`127.0.0.1`）的回环连接就绪；其中 144 个
  一直存活到断开、收到超过 14 字节，即 sing-box 回了 SOCKS 应答并转发了数据。
- 19:15:57.274 之后，没有任何回环连接再出现 `Socket received CONNECTED`。到 19:16:18
  共 396 次 `flow:start_connect`，全部在同一个线程上执行；此前同类事件分散在 6 个线程。
- 每个新连接的路径评估耗时随卡住的连接数线性增长：1 ms → 9 ms → 41 ms → 71 ms。
- 19:16:06 起 Tailscale 的 DNS 全部超时；整段期间 VPN 会话一直是 connected，
  `line-recovery-conditions` 每分钟仍报 `code=ok`，没有任何恢复动作。
- 19:16:18 nesessionmanager 收到 XDial 的停止命令（reason 1）；sing-box 22 ms 内关闭。
  连接报告却记为 `provider-session-lost`“XDial 数据面意外退出”。

复现（同一台 Mac、同一 Profile）：
- 3 轮、每轮 150 个 TCP + 300 个 UDP DNS 流量，间隔 1 s。修复前 TCP 成功 0–8 个、UDP 0 个，
  探测连续失败约 20 s，靠脚本自动断开恢复；日志特征与现场相同（无 CONNECTED、单线程、
  路径评估变慢）。
- 卡死期间在 Provider 之外用 BSD 套接字每秒连 sing-box 入口并发 SOCKS 问候：每次
  0.2–0.4 ms 连上并收到 `05 02`。sing-box 与内核一直正常。
- 与 XDial 无关的独立进程，向本机监听端口突发创建 `NWConnection`：100、200 个立即就绪；
  300 个约 3 s；500 个 5–10 s；800 个 20 s 后只就绪 2 个。同样数量的 BSD `connect()`
  1 s 内全部完成。每连接独立队列、`requiredInterfaceType = .loopback`、`preferNoProxies`
  都不改变结果；限制同时在途 64 个时，就绪速率随存活连接数下降（约 190/s → 26/s）。

推的：
- Network.framework 在进程内串行处理所有 `NWConnection` 的内部工作，单连接开销随存活
  连接数增长。突发创建使其饱和后，连接结果不再交付，卡住的连接越积越多，开销继续增长，
  不会自行恢复。
- 手动断开被记成数据面意外退出：显式停止时宿主把已提交的报告留给 Provider 收尾，断开通知
  到达时宿主副本仍是 committed，断开投影把它当作会话丢失。

## 确定的缺口

- Provider 为每个被接管的 TCP 流量开一个、每个 UDP 关联开两个到 sing-box 的回环
  `NWConnection`。在有数百个存活连接的机器上，几百个新流量的突发就足以让全部流量卡死；
  这些连接没有超时，也没有任何检测。
- 断开投影不区分“用户撤回的已提交事务”和“丢失的已提交会话”。

## 修复

- TCP 流量与 UDP 关联到 sing-box 的回环连接改用非阻塞 BSD 套接字
  （[RelaySocket.swift](../../macos/Shared/RelaySocket.swift)），由 GCD 读写源驱动，没有
  进程级串行点。错误仍以 `NWError.posix` 抛出，诊断码与关流错误归类不变；立即取消用
  `SO_LINGER 0` 复位，与 `forceCancel()` 的拆除契约一致。LAN 共享监听器不在此列。
- 宿主记录自己显式停止的事务；该事务断开时按撤回收尾为 `cancelled`
  （`PersistedTransactionReconciliation.decideDisconnectedCommitted`）。

## 验证

- 单测：1000 个回环连接突发 41 ms 内全部完成；收发与半关闭、拒绝连接错误、关闭使挂起的
  接收失败、UDP 往返、关闭后描述符全部释放；macOS 单测 970 个全部通过。
- 安装修复后的 Debug 重放复现：上述 3 轮全部成功、探测无失败；5 轮、每轮 400 TCP +
  800 UDP 两次共 12000 个流量无失败。同条件下回装修复前的 main 构建再次卡死。
- 突发期间往返切换两次场景均提交、探测无失败；突发中断开 26 ms 完成停止，重连正常；
  手动断开后报告为 `cancelled`、无错误。
- 期间发现 `dig @100.100.100.100`（MagicDNS）在 XDial 连接时超时、断开时正常；修复前
  的 main 构建表现相同，与本次改动无关，另行处理。
