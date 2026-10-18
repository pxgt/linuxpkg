# linuxpkg

**English summary.** linuxpkg is a pure-MoonBit toolkit (library + command line) that builds,
inspects and verifies Linux packages. From one JSON file it produces Debian/Ubuntu/UOS/Kylin
`.deb` packages without `dpkg-deb` and `.rpm` packages (Fedora, openEuler, Anolis) without `rpmbuild`,
and it can read and check existing `.deb` and `.rpm` files. Nothing is shelled out: because tar, ar and gzip
are implemented in MoonBit, it runs on the wasm, wasm-gc, js and native backends, so you can build
Linux packages on Windows or macOS. Output depends only on the input, so builds are reproducible.
Every package we write is checked against the official tools (`dpkg-deb`, `dpkg -i`, `lintian`, `rpm -K`,
`rpm -V`, `rpm2cpio`) and installed in Debian, Ubuntu, Fedora and openEuler containers in CI.

> 状态：0.1.0 已发布到 mooncakes（`Xpeng/linuxpkg`）。deb 和 rpm 的构建、检查、校验都已可用。

## 它是什么

linuxpkg 是一个**纯 MoonBit** 实现的 Linux 软件包构建与检查工具，包括一个库和一个命令行程序。
同类工具有 Go 的 [nFPM](https://github.com/goreleaser/nfpm)、Ruby 的 fpm、Rust 的 cargo-deb。

- 用一份 `linuxpkg.json`，把任意程序和文件打成 Debian / Ubuntu / 统信 UOS / 麒麟用的 `.deb`
  以及 Fedora / openEuler / 龙蜥用的 `.rpm`。
- 能读取、检查、校验已有的 `.deb` 和 `.rpm`（包括官方工具生成的包）。
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
| 构建 `.rpm`（文件摘要 SHA-256、头部摘要、payload 摘要、依赖关系、脚本、配置文件） | ✅ |
| 读取 / 检查 / 校验 `.rpm`（头部摘要、payload 摘要、每个文件的摘要） | ✅ |
| cpio（newc）读写 | ✅ |
| 依赖关系：`depends`、`recommends`、`suggests`、`conflicts`、`replaces`、`provides`（带版本约束） | ✅ |
| 读取 xz / zstd 压缩的包的元数据（`inspect`） | ✅ |
| 校验 xz / zstd 压缩的包的文件内容 | ❌ 明确报 unsupported |

## 安装与构建

作为库使用（需要 MoonBit 工具链 `moon` 0.1.20261012 或更新）：

```sh
moon add Xpeng/linuxpkg
```

然后在 `moon.pkg` 里按需导入子包：`Xpeng/linuxpkg/spec`（包模型与配置）、`Xpeng/linuxpkg/deb`、`Xpeng/linuxpkg/rpm`、
`Xpeng/linuxpkg/archive/tar`、`Xpeng/linuxpkg/archive/ar`、`Xpeng/linuxpkg/archive/cpio`。核心库不碰文件系统，可在所有后端运行。

不安装，直接运行已发布的命令行程序（`moonx` 会下载预编译的 wasm 版本，文件路径请用绝对路径）：

```sh
moonx Xpeng/linuxpkg/cmd/main@0.1.0 inspect /绝对路径/hello_1.0.0-1_all.deb
moonx Xpeng/linuxpkg/cmd/main@0.1.0 verify /绝对路径/hello-1.0.0-1.noarch.rpm
```

命令行程序也可以从源码构建：

```sh
git clone https://github.com/pxgt/linuxpkg
cd linuxpkg
moon build --target native cmd/main    # Windows 上请用 wasm-gc，或在 WSL 里用 native
moon run cmd/main --target wasm-gc -- --help
```

## 快速开始

```sh
linuxpkg init                                    # 写出一份示例 linuxpkg.json
linuxpkg build examples/hello/linuxpkg.json --out dist     # 同时生成 deb 和 rpm（--format deb|rpm|all）
linuxpkg inspect dist/hello_1.0.0-1_all.deb      # 看元数据和文件列表
linuxpkg inspect dist/hello-1.0.0-1.noarch.rpm --json
linuxpkg verify dist/hello-1.0.0-1.noarch.rpm    # 退出码 0 表示通过
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
- 我们生成的 rpm → `rpm -K`（头部与 payload 的 SHA-256 摘要 OK）、`rpm -qip`、`rpm -qlp`、`rpm -qcp`、`--scripts`、`--requires/--provides`、
  `rpm2cpio | cpio` 解出的文件与源文件逐字节相同；在私有 `--root` 里 `rpm -i`、`rpm -V`（无差异）、`rpm -e`；
  在 Fedora 41、openEuler 24.03 LTS 容器里 `rpm -ivh` / `dnf install` 都能装、能跑、脚本会执行、能卸载。
- 官方工具生成的包（`dpkg-deb` 的 gzip / xz deb，`rpmbuild` 的 gzip / xz / zstd rpm）→ 我们的 `inspect` / `verify` 能正确读取，
  rpm 的 SHA-1 / MD5 / SHA-256 头部摘要、payload 摘要和每个文件的摘要都会核对；xz / zstd 压缩的内容会明确报“不支持的压缩”，不会崩溃。
- Fedora 官方仓库里下载的真实 rpm（zstd payload）：`inspect` 读到的名称、版本、release、架构、文件列表与 `rpm -qp` 一致。
- 我们写出的 ustar 归档与 GNU tar 1.34 逐字节一致；GNU tar 写出的 ustar / pax / gnu 三种格式我们都能读回。
- 同样的输入构建两次，结果逐字节相同；wasm、wasm-gc、native 产出相同的包。

一个实测发现：Ubuntu 22.04 的 `dpkg -i` 解不了 PAX 扩展头（`unsupported PAX tar header type 'x'`），
所以 deb 里的长路径使用 GNU `L`/`K` 长名条目，与 `dpkg-deb` 自己的做法一致。

## 质量数字

- 测试：179 个，wasm-gc、wasm、js、native 四个后端全部通过。
- 核心包行覆盖率 **95.7%**（spec 97.6%、tar 97.3%、ar 96.4%、cpio 100%、deb 94.3%、rpm 94.1%、gunzip 88.2%），CI 强制不低于 80%（`tools/check_core_coverage.py`）。
- 恶意输入：tar、ar、cpio、deb、rpm 的每一种截断和每个字节翻转都只会得到结果或明确的错误，不会崩溃；gzip 炸弹在解压时就被上限截住。

文档：[配置参考](docs/config.md)、[格式说明与和规范的差异](docs/formats.md)、[如何复现所有验证](docs/verification.md)、
[贡献指南](CONTRIBUTING.md)、[安全策略](SECURITY.md)。

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
- rpm 的头部布局、tag 与不可变区域参考 [google/rpmpack](https://github.com/google/rpmpack)（Apache-2.0）的格式知识，以 rpm 官方工具的实测结果为准，用 MoonBit 重新实现，没有复制代码。
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
