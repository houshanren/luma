拾光 Luma 安装说明

安装
1. 把 Luma.app 拖进「应用程序」文件夹。
2. 首次打开如果提示「无法打开，因为无法验证开发者」：
   - 在 Finder 里右键 Luma.app → 打开 → 再点一次「打开」；
   - 或者在「终端」执行：
     xattr -dr com.apple.quarantine /Applications/Luma.app
3. 之后正常双击即可。

系统要求
- macOS 14.0 或更高
- 支持 Apple 芯片（M1 / M2 / M3 / M4 等）与 Intel 芯片

已内置
- FFmpeg 与 ffprobe，无需另外安装
  · Apple 芯片：ffmpeg-full + libplacebo + MoltenVK，支持杜比视界 RPU 映射
  · Intel 芯片：静态 ffmpeg，支持 zscale 色调映射（HDR10 / HLG）；杜比视界 P5 会退回普通映射
- 本地模型：YOLO11n、地点库等（SigLIP2 由用户在设置里按需下载）

说明
这是本地签名版本，未做 Apple 公证，所以首次打开需要上面第 2 步手动放行。
应用只在本机读写图库与配置，不需要登录任何账号。
