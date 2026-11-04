"""用 ONNX 模型算一段录音的 emissions，存成 little-endian f32（每帧 28 个），给 yuyue fa。

用法：python em_onnx.py <模型.onnx> <录音> <输出.f32>
窗口和 fa.py 一样：每 30 秒一窗，前后各多看 2 秒，只留中间；每窗自己做 layer norm。
"""
import sys
import time

import librosa
import numpy as np
import onnxruntime as ort

SR = 16000
model, audio, out = sys.argv[1:4]
s = ort.InferenceSession(model, providers=["CPUExecutionProvider"])
wav, _ = librosa.load(audio, sr=SR, mono=True)
t0 = time.time()
hop, ctx = 30 * SR, 2 * SR
outs = []
for start in range(0, len(wav), hop):
    a, b = max(0, start - ctx), min(len(wav), start + hop + ctx)
    x = wav[a:b].astype(np.float32)
    x = (x - x.mean()) / np.sqrt(x.var() + 1e-5)
    e = s.run(None, {"wav": x[None, :]})[0][0]
    fps = e.shape[0] / ((b - a) / SR)
    lo = int(round((start - a) / SR * fps))
    hi = lo + int(round(min(hop, len(wav) - start) / SR * fps))
    outs.append(e[lo:hi])
em = np.concatenate(outs).astype("<f4")
em.tofile(out)
print(f"{audio}: {len(wav)/SR:.1f} 秒录音，{em.shape[0]} 帧，模型 {time.time()-t0:.0f} 秒；秒数 {len(wav)/SR}")
