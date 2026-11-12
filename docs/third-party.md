# 对应源码与第三方构建

发布中的 `TunnelOne-<版本>-corresponding-source.tar.gz` 包含：

```text
TunnelOne/            该 commit 的完整跟踪源码、脚本、锁文件与许可证
upstream/             固定 Mihomo commit 的源码归档、upstream vendor 归档
go-modules/           WireGuard bridge 与 launcher 的固定 Go 依赖源码
SOURCE-MANIFEST.txt    版本说明
```

Mihomo 二进制是 upstream 的 `go120` macOS arm64 / amd64-v1 构建，经 `lipo` 合并，内容由 `dependencies.lock.json` 固定并校验。没有修改其源代码；TunnelOne 的约束由独立 launcher 生成派生配置实现。

## 重建 Mihomo

1. 解压 `upstream/mihomo-<commit>.tar.gz`。
2. 在该目录解压 `mihomo-vendor.tar.gz`，得到 `vendor/`。
3. 按其中 `.github/workflows/build.yml` 的 `go120` 路线和 `.github/rename-go120.sh` 处理兼容源码与构建参数。
4. 为 `darwin/arm64` 和 `darwin/amd64`（`GOAMD64=v1`）构建，再用 `lipo` 合并。

上游协议兼容工具链由其 workflow 定义；不同 Go 版本会影响协议支持。不要把本项目的 WireGuard bridge Go 1.19.13 当作 Mihomo 的构建版本。完整上游 release 保留在：

- https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34
- https://github.com/MetaCubeX/mihomo/tree/0455d0d28c4526937380505153e65a843d8612e8

## 重建应用与 launcher

在 `TunnelOne/` 目录按 README 运行构建脚本。Go 依赖也可以从 `go-modules/` 导入本地模块缓存进行离线构建；标准在线构建由各自 `go.sum` 校验。Xcode 与 Go 编译器属于构建工具，不包含在应用源码归档中。

所有原始版权声明和许可证保留在相应组件源码内。仓库 `ThirdParty/` 内还附带主要组件的声明。
