# linuxpkg

**English summary.** linuxpkg is a pure-MoonBit toolkit (library + command line) that builds,
inspects and verifies Linux packages. From one JSON file it produces Debian/Ubuntu/UOS/Kylin
`.deb` packages without `dpkg-deb`, and it can read and check existing `.deb` files. RPM support
(Fedora, openEuler, Anolis) is under development. Nothing is shelled out: because tar, ar and gzip
are implemented in MoonBit, it runs on the wasm, wasm-gc, js and native backends, so you can build
Linux packages on Windows or macOS. Output depends only on the input, so builds are reproducible.
Every package we write is checked against the official tools (`dpkg-deb`, `dpkg -i`, `lintian`) in CI.

> 状态：开发中（0.0.1，尚未发布到 mooncakes）。deb 的构建、检查、校验已可用；rpm 正在开发。

## 它是什么

linuxpkg 是一个**纯 MoonBit** 实现的 Linux 软件包构建与检查工具，包括一个库和一个命令行程序。
同类工具有 Go 的 [nFPM](https://github.com/goreleaser/nfpm)、Ruby 的 fpm、Rust 的 cargo-deb。

- 用一份 `linuxpkg.json`，把任意程序和文件打成 Debian / Ubuntu / 统信 UOS / 麒麟用的 `.deb`
  （后续加上 Fedora / openEuler / 龙蜥用的 `.rpm`）。
- 能读取、检查、校验已有的 `.deb`。
- **不依赖** `dpkg-deb`、`rpmbuild` 等系统工具，所以在 Windows、macOS 上也能产出 Linux 包。
- **可复现构建**：同样的输入逐字节产出同样的包（支持 `SOURCE_DATE_EPOCH`）。
- 核心库不碰文件系统，可在 wasm / wasm-gc / js / native 四个后端运行；只有命令行读写文件。

## 当前功能

| 功能 | 状态 |
|---|---|
| 构建 `.deb`（control、md5sums、conffiles、维护者脚本、软链接、目录、属主属组） | ✅ |
| 读取 / 检查 `.deb`（`inspect`，含 `--json`） | ✅ |
| 校验 `.deb`（`verify`：md5sums、gzip 校验和、路径安全） | ✅ |
| tar（ustar / PAX / GNU 长名）读写、ar 读写 | ✅ |
| `linuxpkg.json` 配置、依赖关系（`libc6 (>= 2.31)`） | ✅ |
| 构建 / 检查 / 校验 `.rpm` | 🚧 开发中 |
| cpio（newc）读写 | 🚧 开发中 |

## 安装与构建

目前从源码使用（需要 MoonBit 工具链 `moon` 0.1.20261012 或更新）：

```sh
git clone https://github.com/pxgt/linuxpkg
cd linuxpkg
moon build --target native cmd/main    # 命令行程序，Windows 上请用 wasm-gc 或在 WSL 里用 native
moon run cmd/main --target wasm-gc -- --help
```

发布到 mooncakes 之后，库将作为 `Xpeng/linuxpkg` 提供：`moon add Xpeng/linuxpkg`。

## 快速开始

```sh
linuxpkg init                                    # 写出一份示例 linuxpkg.json
linuxpkg build examples/hello/linuxpkg.json --out dist
linuxpkg inspect dist/hello_1.0.0-1_all.deb      # 看元数据和文件列表
linuxpkg inspect dist/hello_1.0.0-1_all.deb --json
linuxpkg verify dist/hello_1.0.0-1_all.deb       # 退出码 0 表示通过
```

退出码：`0` 成功；`1` 用法错误、文件读不了、不是包、或用了不支持的压缩；`2` `verify` 发现包损坏或被篡改。

### 配置文件

[`examples/hello/linuxpkg.json`](examples/hello/linuxpkg.json) 是一个完整例子：

```json
{
  "name": "hello",
  "version": "1.0.0",
  "release": "1",
  "arch": "all",
  "maintainer": "Your Name <you@example.org>",
  "description": "一行摘要\n后面几行是详细说明",
  "mtime": 1700000000,
  "depends": ["libc6 (>= 2.31)"],
  "contents": [
    { "src": "hello.sh", "dst": "/usr/bin/hello", "mode": "0755" },
    { "src": "hello", "dst": "/usr/bin/hi", "type": "symlink" },
    { "src": "hello.conf", "dst": "/etc/hello.conf", "type": "config" },
    { "dst": "/var/lib/hello", "type": "dir" }
  ],
  "scripts": { "postinstall": "scripts/postinst.sh" }
}
```

- 字段名参考 nFPM；`contents[].type` 可以是 `file`（默认）、`config`、`dir`、`symlink`；
  `mode` 写成八进制字符串（`"0755"`）；`owner` / `group` 默认 `root`；
  也可以把 `mode`、`owner`、`group`、`mtime` 放进 nFPM 风格的 `file_info`。
- `arch` 接受 `amd64`、`x86_64`、`arm64`、`aarch64`、`all`、`noarch` 等写法，会自动换成 deb / rpm 各自的名字。
- 版本里的预发布用 `~`（`1.0~rc1`），不要用 `-`。
- 路径必须是绝对路径，不能含 `..`，不能重复；错误信息会指出出错的字段（如 `contents[2].dst`）。
- 没写 `mtime` 时，用环境变量 `SOURCE_DATE_EPOCH`，再没有就用 0。

## 它是怎么被验证的

我们不只相信自己的单元测试，而是让**官方工具**来当裁判（`tools/oracle/run.sh`，每次推送都在 CI 里跑）：

- 我们生成的 deb → `dpkg-deb --info/--contents/--extract`、`dpkg -i`、`dpkg --verify`、`dpkg -r`、`dpkg -P` 都接受，装好后程序能运行，
  配置文件在 `dpkg -r` 时保留、`dpkg -P` 时清除；`lintian` 的结果会记录下来。
- 官方工具生成的 deb（`dpkg-deb` 1.21 的 gzip / xz 包）→ 我们的 `inspect` / `verify` 能正确读取；xz 会明确报“不支持的压缩”，不会崩溃。
- 我们写出的 ustar 归档与 GNU tar 1.34 逐字节一致；GNU tar 写出的 ustar / pax / gnu 三种格式我们都能读回。
- 同样的输入构建两次，结果逐字节相同；wasm、wasm-gc、native 产出相同的包。

一个实测发现：Ubuntu 22.04 的 `dpkg -i` 解不了 PAX 扩展头（`unsupported PAX tar header type 'x'`），
所以 deb 里的长路径使用 GNU `L`/`K` 长名条目，与 `dpkg-deb` 自己的做法一致。

## 范围与不做的事

不做：

- 包签名（GPG / PGP）、软件仓库元数据（apt 的 Release/Packages、yum 的 repodata）
- xz / zstd / lzma / bzip2 压缩（只支持 gzip 和不压缩；读到其他压缩会报 `unsupported`）
- Alpine apk、Arch pkg、源码包（`.dsc`、`.src.rpm`）
- 自动分析二进制的动态库依赖
- 运行维护者脚本（只负责打包，不负责安装）

已知限制：文件的权限位和修改时间不从磁盘读取（MoonBit 的文件 API 拿不到），一律由配置决定，这也正好保证可复现。
文件属主在 tar 里写名字，数字 id 固定为 0，由包管理器按名字解析。

## 相关项目与致谢

- MoonBit 生态里已有 [`xmyd0915/moonar`](https://mooncakes.io/docs/xmyd0915/moonar)（ar 归档）和
  [`oilleelssq-wq/moon-cpio`](https://mooncakes.io/docs/oilleelssq-wq/moon-cpio)（cpio 归档）两个底层零件。
  linuxpkg 自己实现了 ar / tar / cpio，是为了完全控制确定性输出，并让归档格式与打包逻辑一起被官方工具验证；对这两个项目表示尊重。
- 配置字段命名参考 [nFPM](https://github.com/goreleaser/nfpm)（MIT）。
- rpm 格式将参考 [google/rpmpack](https://github.com/google/rpmpack)（Apache-2.0）的格式知识，用 MoonBit 重新实现，不逐行翻译。
- gzip 来自 [moonbit-community/flate](https://mooncakes.io/docs/moonbit-community/flate)，摘要来自 `moonbitlang/x/crypto`。

详见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 开发

```sh
moon fmt --check
moon info && git diff --exit-code          # 公开接口 pkg.generated.mbti 要保持最新
moon check --target all --deny-warn
moon test --target wasm-gc                 # 也可以换 js、wasm；native 在 Linux/WSL 上跑
tools/oracle/run.sh                        # 需要 dpkg-deb、dpkg、sudo（可选 lintian）
```

目录：`spec/`（包模型、配置、校验）、`archive/tar|ar/`（归档格式）、`deb/`（deb 构建与读取）、`cmd/main/`（命令行）、
`examples/`（示例）、`tools/oracle/`（官方工具验证脚本）。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
