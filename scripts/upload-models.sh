#!/bin/sh
# 把强制对齐模型传到 GitHub Releases 的 models-1。
# 三端第一次合成有声书时从这里下载，下载后核对 BLAKE3，对不上就不用。
#
# 用法：scripts/upload-models.sh <模型所在文件夹> [仓库]
#   仓库默认 left-in/yuyue
# 先 gh auth login。仓库必须是公开的，否则别人下载是 404。
# 换了仓库，要同时改 apple/Yuyue/App/Aligner.swift 和
# android/app/src/main/java/app/yuyue/speech/Aligner.kt 里的地址。
set -eu
DIR=${1:?要给模型所在文件夹}
REPO=${2:-left-in/yuyue}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
YUYUE=$ROOT/core/target/release/yuyue

check() { # 文件 应有的 BLAKE3（和 App 里写的一致）
  got=$("$YUYUE" digest "$1")
  [ "$got" = "$2" ] || { echo "$1 的 BLAKE3 是 $got，App 要的是 $2，不传" >&2; exit 1; }
}
APPLE=$(sed -n 's/.*static let digest = "\(.*\)".*/\1/p' "$ROOT/apple/Yuyue/App/Aligner.swift")
DROID=$(sed -n 's/.*DIGEST = "\(.*\)".*/\1/p' "$ROOT/android/app/src/main/java/app/yuyue/speech/Aligner.kt")
check "$DIR/MMSAligner.mlmodelc.zip" "$APPLE"
check "$DIR/mms_fa.int8.onnx" "$DROID"

[ "$(gh repo view "$REPO" --json visibility -q .visibility)" = PUBLIC ] || { echo "$REPO 不是公开仓库，别人下载会是 404" >&2; exit 1; }
gh release view models-1 -R "$REPO" >/dev/null 2>&1 || gh release create models-1 -R "$REPO" --title "对齐模型 1" --notes "语阅有声书用的强制对齐模型：Meta MMS（facebook/mms-300m 的对齐版，torchaudio MMS_FA），8 位量化。许可 CC-BY-NC 4.0，只许非商用。App 第一次合成有声书时自动下载，不用手动装。"
gh release upload models-1 -R "$REPO" --clobber "$DIR/MMSAligner.mlmodelc.zip" "$DIR/mms_fa.int8.onnx"

for f in MMSAligner.mlmodelc.zip mms_fa.int8.onnx; do
  code=$(curl -sIL -o /dev/null -w '%{http_code}' "https://github.com/$REPO/releases/download/models-1/$f")
  echo "$f → $code"
done
