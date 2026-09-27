# 任务级套接字绑定补丁

这里保留 **reqwest 0.13.4** 与 **hyper-util 0.1.20** 发布版本的上游源码和许可证。根 Cargo 清单通过 `[patch.crates-io]` 使用本地副本，版本与无关行为保持不变。由于副本包含本地修改，仅移除了注册表安装标记与旧校验文件。

## 维护范围

- `reqwest/src/async_impl/client.rs`：可选的客户端独立 `Arc<Fn(&socket2::Socket) -> io::Result<()> + Send + Sync>` 配置、`ClientBuilder::socket_callback`、只表示是否配置的调试字段，以及在 TLS 包装之前向既有 `HttpConnector` 传递回调。两个清单为非浏览器目标声明 socket2 0.6.5。
- `hyper-util/src/client/legacy/connect/http.rs`：可克隆的连接器配置增加可选回调，提供 `set_socket_callback`，在每个 TCP 套接字创建后、绑定与连接前调用。既有测试的配置字面量补上 `None`。
- hyper-util 两个清单将原有 `>=0.5.9, <0.7` socket2 范围收窄到项目已有的 `0.6.5`，确保两个 crate 的回调借用同一种 Socket 类型。
- 默认值均为 `None`，没有全局回调，不转移原始套接字所有权，不升级依赖，不修改 TLS 握手、证书校验或传输协议。

回调失败会关闭刚创建的套接字并使该连接尝试失败。后续地址尝试仍执行同一回调，绝不改用未绑定套接字重试。连接池内已有连接保持原绑定，应用仍需像 LegnaSend v2 客户端一样在每次请求前核验所选路由。

回调覆盖普通 TCP 连接器及其 TLS 包装。QUIC、Unix 套接字、命名管道和 SOCKS 具有其他连接路径，**不在覆盖范围内**。LegnaSend 的指定出口客户端禁用代理并使用原版 LocalSend v2 HTTP/TLS TCP 路径；扩展其他传输方式前应先实现等价约束。

## 更新上游时的检查清单

1. 仅重新应用上述补丁，保留上游许可文本。
2. 审查连接器创建与其他传输路径，防止出现新的绕过分支。
3. 执行 `cargo test -p localsend --features full --test client_socket_callback --test client_local_route`。
4. 检查 Windows 与 Android 目标编译；在对应系统运行平台接口或 Network 测试后再声明运行态通过。
5. 保持绑定失败即终止、不修改进程级网络绑定的行为。

微软文档规定：IPv4 `IP_UNICAST_IF` 使用网络字节序接口索引，IPv6 `IPV6_UNICAST_IF` 使用主机字节序：[IPv4 套接字选项](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ip-socket-options)、[IPv6 套接字选项](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ipv6-socket-options)。
