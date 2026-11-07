#!/bin/bash
# 全窗口图册:把 app 的每个窗口和弹窗各截一张。用法: scripts/window-catalog.sh [输出目录]
#
# 原理:app 的 debug 启动参数(-debug*)一次开一个弹窗,app 自己截图(-debugShots,截自己的
# 窗口不需要屏幕录制权限),存完退出。真 app 有 App Sandbox,容器外写不了,所以拷一份构建
# 出来重签成不带沙箱的副本(只给图册跑),输出、临时书库都直接放仓库的输出目录。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_OUT="${1:-$ROOT/build/window-catalog}"
SRC_APP="$ROOT/apple/build/dd/Build/Products/Debug/Yuyue.app"
APP_DIR="$REPO_OUT/YuyueCatalog.app"
APP="$APP_DIR/Contents/MacOS/Yuyue"
LIB="$REPO_OUT/scratch-library"
SEED="$REPO_OUT/seed"
SHOTS="$REPO_OUT/shots"
MANIFEST="$REPO_OUT/manifest.tsv"
mkdir -p "$REPO_OUT" "$SEED" "$SHOTS"
rm -f "$REPO_OUT"/*.log

# —— 拷一份 debug 构建,去掉 App Sandbox 重签(图册专用的副本,真 app 不受影响) ——
ENT="$REPO_OUT/no-sandbox.entitlements"
cat > "$ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
</plist>
EOF
rm -rf "$APP_DIR"
cp -R "$SRC_APP" "$APP_DIR"
# 换个 bundle id:钥匙串按签名+id 认条目,不改的话读真 app 存的 API key 会弹 ACL
# 授权又弹不出来,主线程死等(设置 · 书伴/朗读 页就是这么挂的)。换了就查无此条,
# 页面显示「未连接」,图册本来也不该带真密钥。
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.yuyue.YuyueCatalog" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - --entitlements "$ENT" "$APP_DIR" 2>/dev/null || { echo "重签失败"; exit 1; }

run() { # run 名字 延迟秒 一句话 -debugXXX ...
  local name="$1" delay="$2" what="$3"; shift 3
  rm -rf "$SHOTS/$name"
  printf '%s\t%s\n' "$name" "$what" >> "$MANIFEST"
  "$APP" -debugLibrary "$LIB" -debugNoKeychain 1 -debugShots "$SHOTS" -debugShotName "$name" \
    -debugShotDelay "$delay" "$@" > "$REPO_OUT/$name.log" 2>&1 &
  caffeinate -u -i -w $! > /dev/null 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 120 ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then echo "  超时,杀掉 $name"; kill "$pid"; fi
  sleep 1
  if [ -f "$SHOTS/$name/1.png" ]; then echo "✓ $name"; else echo "✗ $name (没截到,看 $name.log)"; fi
}

: > "$MANIFEST"

# 临时书库从零开始,每趟都一样。
rm -rf "$LIB"

# —— 种子:导入三本书(这一趟顺便把导入卡片截下来),下一趟才是干净的书架 ——
run shelf-import 14 "书架 · 导入卡片(三本书进来)" -debugImport "$ROOT/fixtures/books/hongloumeng.epub|$ROOT/fixtures/books/great-gatsby.epub|$ROOT/fixtures/books/beiying-gbk.txt"
run shelf 5 "书架(红楼梦、了不起的盖茨比、背影 三本)"

# —— 书架各页 ——
run shelf-podcasts 8 "书架 · 播客页(两个节目、几集文稿)" -debugEpisodes 1 -debugPodcast 1
run shelf-notes 4 "书架 · 笔记页" -debugFilter notes
run shelf-words 4 "书架 · 生词页" -debugFilter words
run shelf-audio 4 "书架 · 有声书页" -debugFilter audio
run shelf-collections 5 "书架(侧栏里有两个合集)" -debugCollections "睡前故事|科幻"
run shelf-quick 5 "搜索 · 问(⌘K,书架窗)" -debugQuick 父亲
run shelf-menu 4 "书的右键卡片" -debugMenu 1
run shelf-pick 4 "加入合集(调试钉住的卡片)" -debugPick 1
run shelf-pop 4 "加入合集(真的 popover)" -debugPop 1
run shelf-edit 4 "编辑信息(书名、作者、封面)" -debugEdit 1
run shelf-toast 4 "撤销横幅(Toast)" -debugToast 1
run shelf-drop 4 "拖三份文件进来时的提示" -debugDrop 3
run shelf-conflict 5 "笔记冲突(同步冲突弹窗)" -debugConflict 1
run shelf-desk 5 "播客 · 编辑部(写稿台)" -debugPodcast desk
run shelf-show-make 5 "配一档节目(节目编辑表)" -debugPodcast make

# —— 设置(前台那扇就是设置窗,共十页) ——
run settings-general 4 "设置 · 通用" -debugSettings general
run settings-appearance 4 "设置 · 外观" -debugSettings appearance
run settings-reading 4 "设置 · 阅读" -debugSettings reading
run settings-foreign 4 "设置 · 外文" -debugSettings foreign
run settings-listening 4 "设置 · 朗读" -debugSettings listening
run settings-companion 4 "设置 · 书伴" -debugSettings companion
run settings-sync 4 "设置 · 同步" -debugSettings sync
run settings-notes 4 "设置 · 笔记导出" -debugSettings notes
run settings-storage 4 "设置 · 存储" -debugSettings storage
run settings-data 4 "设置 · 数据" -debugSettings data
run settings-history 5 "设置 · 最近改过(侧栏底的 popover)" -debugSettings general -debugHistory 1
run settings-companion-add 5 "设置 · 书伴 添加服务商(sheet)" -debugSettings companion -debugCompanion add
run settings-cloudvoice 5 "设置 · 朗读 接云端声音" -debugSettings listening -debugCloudVoice openai
run settings-notes-obsidian 5 "设置 · 笔记导出 选中 Obsidian" -debugSettings notes -debugNotes obsidian

# —— 读书窗 ——
run reader 6 "读书窗(红楼梦正文)" -debugOpen 红楼
run reader-toc 5 "读书窗 · 目录面板" -debugOpen 红楼 -debugPanel toc
run reader-notes 5 "读书窗 · 笔记面板(带几条划线)" -debugOpen 红楼 -debugPanel notes -debugSeed 1
run reader-words 5 "读书窗 · 笔记面板 生词页" -debugOpen 红楼 -debugPanel notes -debugNotesTab words
run reader-companion 5 "读书窗 · 书伴面板" -debugOpen 红楼 -debugPanel companion
run reader-search 5 "读书窗 · 书内搜索(搜「父亲」)" -debugOpen 红楼 -debugPanel search -debugQuery 父亲
run reader-rules 5 "替换规则(sheet)" -debugOpen 红楼 -debugRules 1
run reader-txt 5 "编码和目录(TXT 用的 sheet)" -debugOpen 背影 -debugTxt 1
run reader-typeset 5 "排版卡(工具栏 popover)" -debugOpen 红楼 -debugTypeset 1
run reader-listen 6 "听书卡(胶囊 popover)" -debugOpen 红楼 -debugListen 1
run reader-cast 7 "声音班底(听书卡里再开的 sheet)" -debugOpen 红楼 -debugListen 1 -debugCast 1
run reader-word 5 "查词卡(外文书里点一个词)" -debugOpen Gatsby -debugWord fortune
run reader-translate 5 "整句翻译卡(外文)" -debugOpen Gatsby -debugTranslate 1
run reader-select 5 "划线选区卡" -debugOpen 红楼 -debugSelect "2,0,2,9"
run reader-flag 6 "朗读对不上反馈卡" -debugOpen 红楼 -debugFlag 1
run reader-immersive 5 "沉浸阅读" -debugOpen 红楼 -debugImmersive 1

# —— 有声书:say 念一段第一回,看配对/合成页(对齐可能不准,看界面就够) ——
if command -v say > /dev/null && [ ! -f "$SEED/duan.aiff" ]; then
  say -v Tingting -o "$SEED/duan.aiff" --data-format=LEI16@22050 "此开卷第一回也。作者自云,因曾历过一番梦幻之后,故将真事隐去,而借通灵之说,撰此石头记一书也。" 2>/dev/null
fi
if [ -f "$SEED/duan.aiff" ]; then
  run audiobook-make 60 "有声书 · 合成中/合成好了" -debugAudiobook "$SEED/duan.aiff" -debugAudiobookBook 红楼
  run audiobook-page 6 "有声书 · 一本有声书的页" -debugAudiobook 1
  run audiobook-pair 6 "有声书 · 配对(录音配电子书)" -debugPair 1
fi

echo "图册在 $SHOTS/"
