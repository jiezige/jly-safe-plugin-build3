# Cloud build without a Mac

如果没有 Mac，可以用 GitHub Actions 的 macOS 云编译机生成 `cike.dylib`。

## 操作步骤

1. 在 GitHub 新建一个空仓库。

2. 把 `ios-plugin` 目录里的所有文件上传到仓库根目录。

   仓库里应该能看到这些路径：

   ```text
   Makefile
   Tweak.xm
   control
   .github/workflows/build-dylib.yml
   ```

3. 打开 GitHub 仓库页面：

   ```text
   Actions -> Build iOS dylib -> Run workflow
   ```

4. 等待任务完成。

5. 在任务页面底部下载 artifact：

   ```text
   JLYSafePlugin-ios
   ```

6. 解压后会得到：

   ```text
   cike.dylib
   ```

7. 把 `cike.dylib` 放到 Windows 本机：

   ```text
   E:\minimax\1\leyuan\pj\10\ios-plugin\build\cike.dylib
   ```

8. 运行未签名 IPA 打包脚本：

   ```powershell
   powershell -ExecutionPolicy Bypass -File E:\minimax\1\leyuan\pj\10\ios-plugin\repack-unsigned-ipa.ps1
   ```

9. 输出文件：

   ```text
   E:\minimax\1\leyuan\pj\10\o_1jnk690m4gjo1nsd1tai1o441q489_plugin_unsigned.ipa
   ```

10. 最后用你自己的工具签名安装。

## 注意

- GitHub Actions 只是编译 dylib，不保存你的签名证书。
- 当前插件默认只在点击“解锁的付费视频”入口且未激活时弹激活码。若需要启动时就弹，改 `Tweak.xm`：

  ```objc
  static BOOL const kJLYRequireActivationOnLaunch = YES;
  ```

- Worker 需要提供：

  ```text
  GET  /app-update.json
  GET  /api/posts/app-list
  POST /api/posts/ingest-response
  ```
