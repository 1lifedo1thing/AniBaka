# macOS 启动签名检查

当前发布脚本只导入签名证书，没有配置 Apple provisioning profile。
因此 `Runner/Release.entitlements` 和 `Runner/DebugProfile.entitlements`
不能声明 `com.apple.developer.associated-domains`。自签名证书不能授权此权限；
仅更换为 Developer ID 证书也不能代替对应的 provisioning profile。
`codesign --verify` 通过不代表系统允许应用启动。

当前通过 Info.plist 注册的 `anibaka://` 自定义协议唤起应用。
要启用 HTTPS Universal Links，需要配置 Apple App ID 的 Associated Domains、
匹配的签名身份和授权该权限的 profile，并将 profile 嵌入应用后再签名。
届时应同步更新签名脚本的检查，验证实际授权，而不是仅删除检查。

## Issue #29

报告的机器是 Apple M1，运行的是经 Rosetta 转译的 x86_64 版本。
应优先使用 `macos-arm64.dmg`，但更换架构不能保证解决签名权限问题。
日志中的 `SIGKILL (Code Signature Invalid)`、`Taskgated Invalid Signature`
和空调用栈说明应用在启动时被系统拒绝执行。
5.1.1 源码声明了没有在发布流程中配置授权的 Associated Domains，属于与该
症状吻合的配置缺陷；尚未在报告机器上确认它是此次崩溃的唯一原因。

重新构建后，在 macOS 上检查从最终 DMG 安装的应用：

```sh
codesign --verify --deep --strict --verbose=2 /Applications/Baka.app
codesign --display --entitlements :- /Applications/Baka.app
syspolicy_check distribution /Applications/Baka.app
```

还需实际启动应用；若失败，先在终端运行下面命令，再重新打开应用，收集具体的
`Unsatisfied entitlements` 或其他拒绝原因：

```sh
log stream --predicate 'process == "taskgated-helper" or process == "amfid" or process == "syspolicyd"'
```

自签名或未经公证的发行包仍可能不能通过系统分发策略检查。这与修正未授权权限
是不同的发布条件，不能将本地模拟测试视为 Apple 信任、公证或真机启动验证。

参考：[Apple 启动签名崩溃排查](https://developer.apple.com/forums/thread/706427)、
[Apple 信任执行问题排查](https://developer.apple.com/forums/thread/706442)。
