"""对齐准度的考卷：拿每句单独录好的语音拼成“一本有声书”，每句在哪儿是精确知道的。

用法：<装了 librosa、soundfile、webrtcvad 的 python> scripts/align-bench/build.py

来源（都在 bench/dl 下）：
- librispeech：LibriSpeech test-clean，同一个人读同一章，按原顺序拼回去。英文，真人。
- fleurs：FLEURS 普通话 dev，维基百科句子，一句一个人读。中文，真人，人声换来换去（比真书难）。
- kyj-tts：《孔乙己》每句用系统中文声音念。中文，书的原文（繁体、标点、引号），机器声。

每本做四种：
- clean：照原文全读，句间停 0.25–0.9 秒。
- skip：原文里约 6% 的句子录音里没有（像插图说明、注释）。
- extra：开头多 8 秒、中间两处各多 12–20 秒不在原文里的话（像片头、口播广告）。
- both：skip + extra。

每份输出到 bench/cases/<名字>/：audio.wav（16 kHz）、text.tsv（编号⇥原文）、truth.json
（每句说话的起止，录音里没有的是 null；多出来的话的起止；每句前后的停顿）。
"""
import json
import os
import random
import re
import subprocess
import tarfile
import tempfile

import librosa
import numpy as np
import soundfile as sf
import webrtcvad

SR = 16000
# 数据（下载的语料、拼好的考卷、模型）不进仓库，放在 YUYUE_BENCH 指的文件夹。
HERE = os.environ.get("YUYUE_BENCH", "bench")
SCRIPTS = os.path.dirname(os.path.abspath(__file__))
DL = os.path.join(HERE, "dl")
CASES = os.path.join(HERE, "cases")
LAB = os.path.dirname(HERE)


def trim(wav):
    """The clip from where speech starts to where it ends, by WebRTC's voice detector (30 ms
    frames). Speech starts with 0.2 s of voice on end, so a click when the microphone opens
    (FLEURS has many) isn't taken for it; voice up to 0.3 s before that is a short first word
    and counts. The clip keeps 50 ms either side."""
    vad = webrtcvad.Vad(2)
    n = SR * 30 // 1000
    pcm = (np.clip(wav, -1, 1) * 32767).astype("<i2")
    voice = np.array([vad.is_speech(pcm[i:i + n].tobytes(), SR) for i in range(0, len(pcm) - n + 1, n)])
    run, first = 0, None
    for i, v in enumerate(voice):
        run = run + 1 if v else 0
        if run == 7:
            first = i - 6
            break
    if first is None:
        return wav
    while True:
        before = np.where(voice[max(0, first - 10):first])[0]
        if len(before) == 0:
            break
        first = max(0, first - 10) + before[0]
    last = np.where(voice)[0][-1]
    a, b = max(0, first * n - SR // 20), min(len(wav), (last + 1) * n + SR // 20)
    return wav[a:b]


def librispeech():
    """[(book name, [(text, wav)])]: the three longest chapters."""
    root = os.path.join(DL, "LibriSpeech", "test-clean")
    if not os.path.isdir(root):
        with tarfile.open(os.path.join(DL, "ls-test-clean.tar.gz")) as t:
            t.extractall(DL)
    chapters = []
    for spk in os.listdir(root):
        for ch in os.listdir(os.path.join(root, spk)):
            d = os.path.join(root, spk, ch)
            lines = open(os.path.join(d, f"{spk}-{ch}.trans.txt")).read().splitlines()
            chapters.append((len(lines), spk, ch, d, lines))
    chapters.sort(reverse=True)
    out = []
    for _, spk, ch, d, lines in chapters[:3]:
        clips = []
        for line in lines:
            uid, text = line.split(" ", 1)
            wav, _ = sf.read(os.path.join(d, uid + ".flac"), dtype="float32")
            # Books have capitals and punctuation; the transcripts don't. Sentence case at least.
            clips.append((text.lower().capitalize() + ".", trim(wav)))
        out.append((f"librispeech-{spk}-{ch}", clips))
    return out


def fleurs():
    root = os.path.join(DL, "fleurs-dev")
    if not os.path.isdir(root):
        with tarfile.open(os.path.join(DL, "fleurs-cmn-dev.tar.gz")) as t:
            t.extractall(root)
    files = {f: os.path.join(dp, f) for dp, _, fs in os.walk(root) for f in fs if f.endswith(".wav")}
    seen, clips = set(), []
    for line in open(os.path.join(DL, "fleurs-cmn-dev.tsv"), encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        sid, fname, raw = p[0], p[1], p[2]
        if sid in seen or fname not in files:
            continue
        seen.add(sid)
        wav, sr = sf.read(files[fname], dtype="float32")
        if sr != SR:
            wav = librosa.resample(wav, orig_sr=sr, target_sr=SR)
        clips.append((int(sid), raw.strip(), trim(wav)))
    clips.sort()
    clips = [(t, w) for _, t, w in clips]
    h = len(clips) // 2
    return [("fleurs-cmn-a", clips[:h]), ("fleurs-cmn-b", clips[h:])]


def kyj_tts():
    rows = [l.split("\t", 1) for l in open(os.path.join(LAB, "align", "truth", "kyj.tsv"), encoding="utf-8").read().splitlines()]
    cache = os.path.join(DL, "kyj-tts")
    os.makedirs(cache, exist_ok=True)
    clips = []
    # Lines with nothing to read aloud (“ぎ” in the scan) aren't a test of anything.
    rows = [(k, t) for k, t in rows if re.search(r"[\u4e00-\u9fff0-9]", t)]
    for k, text in rows:
        path = os.path.join(cache, f"{k}.aiff")
        if not os.path.exists(path):
            subprocess.run(["say", "-v", "Meijia", "-o", path, text], check=True)
        wav, _ = librosa.load(path, sr=SR)
        clips.append((text, trim(wav)))
    return [("kyj-tts", clips)]


def make(name, clips, others, rng, skip, extra):
    """One recording of `clips` in order, with some left out and `others` put in."""
    n = len(clips)
    left_out = set(rng.sample(range(1, n), max(1, n * 6 // 100))) if skip else set()
    # Extra speech: at the start, and before two sentences in the middle third.
    put_in = {0: 8.0} if extra else {}
    if extra:
        for i in rng.sample(range(n // 3, 2 * n // 3), 2):
            put_in[i] = rng.uniform(12, 20)
    parts, t = [], 0.0
    truth, extras = {}, []

    def add(w):
        nonlocal t
        parts.append(w)
        t += len(w) / SR

    def pause():
        add(np.zeros(int(rng.uniform(0.25, 0.9) * SR), np.float32))

    def chatter(secs):
        a = t
        while t - a < secs:
            add(rng.choice(others))
            pause()
        extras.append([a, t])

    add(np.zeros(int(0.5 * SR), np.float32))
    for i, (text, wav) in enumerate(clips):
        if i in put_in:
            chatter(put_in[i])
        if i in left_out:
            truth[str(i)] = None
            continue
        truth[str(i)] = [round(t, 3), round(t + len(wav) / SR, 3)]
        add(wav)
        pause()
    audio = np.concatenate(parts)
    d = os.path.join(CASES, name)
    os.makedirs(d, exist_ok=True)
    sf.write(os.path.join(d, "audio.wav"), audio, SR, subtype="PCM_16")
    with open(os.path.join(d, "text.tsv"), "w", encoding="utf-8") as f:
        for i, (text, _) in enumerate(clips):
            f.write(f"{i}\t{text}\n")
    json.dump({"seconds": len(audio) / SR, "sentences": truth, "extra": extras}, open(os.path.join(d, "truth.json"), "w"), ensure_ascii=False)
    print(f"{name}: {len(audio)/SR/60:.1f} 分钟，{n} 句，{len(left_out)} 句没念，{sum(b-a for a,b in extras):.0f} 秒多出来的话")


def main():
    rng = random.Random(7)
    books = [(b, "en") for b in librispeech()] + [(b, "zh") for b in fleurs()] + [(b, "zh") for b in kyj_tts()]
    # The extra speech is in the book's own language, from another book.
    for (name, clips), lang in books:
        others = [w for (n2, c2), l2 in books if n2 != name and l2 == lang for _, w in c2]
        for kind, skip, extra in [("clean", False, False), ("skip", True, False), ("extra", False, True), ("both", True, True)]:
            make(f"{name}-{kind}", clips, others, rng, skip, extra)
    meta = {name: lang for (name, _), lang in books}
    json.dump(meta, open(os.path.join(CASES, "books.json"), "w"))


if __name__ == "__main__":
    main()
