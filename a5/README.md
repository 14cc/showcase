# publicsource — 对外公开源(给朋友)

两个子项目,各自独立 git 仓库。**公开发布用,绝不含私钥。**

| 子目录 | 上游 | 分支 | 内容 |
|---|---|---|---|
| `showcase/` | amineross/showcase · Beta 5-1 | `public` | 原版 + 证书离线认证(内置,插上即用);❌ 无投屏/浏览器/域名/限速 |
| `share/`    | amineross/share · Beta 2-5    | `public` | 2-6:原版 + 隐根版运行时找 ElleKit/Substrate(按需发布)|

- `showcase/source/embedded_cert.h` 是空壳(无私钥),可放心公开;打 deb 时本地用真头文件覆盖再编译。
- GPL:公开分发二进制须附源码(本仓库即可)。
- 每个子目录 `./sync-upstream.sh` 拉上游更新。
