# 发布 GitHub 自动更新

从 v1.1.0 开始，应用使用 [Sparkle 2](https://sparkle-project.org/documentation/) 检查 GitHub Releases，默认自动检查和下载，在文件队列完成且应用空闲后安装并重新打开。检查周期约四小时，也可以使用应用中的「检查更新」。关闭自动更新后可以手动检查。

v1.0.x 没有更新器，需要先手动安装一次 v1.1.0 或更新版本。配对密码继续从原有 macOS 钥匙串读取，无需重新输入。当前没有 Developer ID 签名证书，更新后 macOS 可能再次要求允许应用访问已有钥匙串条目；使用稳定的 Developer ID 签名身份可以避免这类签名身份变化。

## 签名和更新源

`Resources/Info.plist` 中配置 GitHub 最新 Release 的 `appcast.xml` 资产地址和 Ed25519 公钥。应用先验证更新目录签名，再验证安装包签名，验证失败时不会安装。下载发生在 GitHub；局域网文件仍只在两台 Mac 之间传输。

发布私钥保存在维护者本机的 macOS 钥匙串，account 为 `com.sikefix.landrop.sparkle`。源码、Release、构建产物和 GitHub Actions 都不包含私钥。需要保留该钥匙串条目以便持续发布；更换公钥应按 [Sparkle 密钥轮换说明](https://sparkle-project.org/documentation/) 提前规划，不能直接替换后期待旧安装自动信任。

GitHub Actions 只验证代码并构建应用。正式更新通过本机官方 `generate_appcast` 工具签名发布。每个 Release 都必须包含安装 ZIP 和已签名 `appcast.xml`；只有 ZIP 的 Release 无法通过该更新源检查。

## 准备新版

1. 修改 `CFBundleShortVersionString`，例如 `1.1.1`，同时严格增加 `CFBundleVersion`，例如从 `3` 增加到 `4`。
2. 更新发布说明并运行 `swift test`，提交所有源代码、依赖锁定文件和说明，推送到 GitHub。
3. 在拥有发布钥匙串的 Mac 上运行：

```sh
./scripts/publish-release.sh --publish docs/releases/v1.1.0.md
```

脚本构建通用应用，检查钥匙串公钥是否与应用一致，签名并验证安装包和更新目录，生成 SHA-256，上传为草稿 Release，最后发布。已有同名版本不会被覆盖。省略 `--publish` 可以只准备和验证；输出保存在 `build/release-版本号/updates/`。准备目录存在时脚本会停止，请检查并移动目录后再运行。

签名后的 `appcast.xml` 不得手动编辑；如需修改应重新生成签名。发布后可下载 Release 中的资产再次验证，验证工具只读取公钥，不访问发布私钥：

```sh
xcrun swift scripts/verify-update.swift Resources/Info.plist appcast.xml LanDrop-macOS-universal-v1.1.0.zip
```

Apple Developer ID 签名和公证独立于 Ed25519 更新签名。当前默认 ad hoc 签名；`LANDROP_SIGN_IDENTITY` 可以指定 Developer ID，构建脚本会用相同身份依次签名 Sparkle 的 XPC、辅助程序、框架和主应用。公证仍需维护者单独完成。

## Fork 项目

Fork 的维护者应为自己的应用生成独立签名密钥，并修改 bundle ID、更新源、公钥及发布脚本中的仓库和钥匙串 account。不要尝试使用上游公钥签名自己的更新，也不要将私钥提交到源码仓库。官方工具通过 `swift package resolve` 下载到 `.build/artifacts/sparkle/Sparkle/bin/`。
