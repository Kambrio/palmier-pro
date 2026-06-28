#!/usr/bin/env python3
"""OmniVoice worker for Palmier. Reads one JSON job on stdin, loads the model once,
generates each segment to its `output` WAV, and streams JSON-line progress on stdout.

Config:
{
  "ref_audio": "/path/ref.wav",   # optional — omit for plain TTS / voice design
  "ref_text": "...",              # optional reference transcription (else auto-ASR)
  "language": "English",
  "num_step": 16,
  "segments": [
    {"text": "Hello", "output": "/tmp/0.wav", "instruct": "female, british accent"}
  ]
}

Output lines:
{"status": "model_ready", "device": "mps", "num_step": 16}
{"status": "job_start", "language": "English", "count": 1}
{"segment": 0, "status": "done", "actual_duration": 3.48, "language": "English"}
{"segment": 0, "status": "cached", "actual_duration": 3.48}
{"segment": 0, "status": "error", "error": "..."}
{"status": "complete", "total": 1, "done": 1, "cached": 0, "errors": 0}
"""

import json
import sys
import time
from pathlib import Path

import torch
import torchaudio

from omnivoice import OmniVoice, OmniVoiceGenerationConfig

SAMPLE_RATE = 24000


def get_device():
    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def emit(obj):
    print(json.dumps(obj), flush=True)


def main():
    config = json.loads(sys.stdin.read())
    language = config.get("language", "English")
    segments = config.get("segments", [])
    ref_audio = config.get("ref_audio")  # may be None

    if not segments:
        emit({"status": "complete", "total": 0, "done": 0, "cached": 0, "errors": 0})
        return

    device = get_device()
    model = OmniVoice.from_pretrained("k2-fsa/OmniVoice", device_map=device)

    prompt = None
    if ref_audio:
        if not config.get("ref_text"):
            model.load_asr_model()
        prompt = model.create_voice_clone_prompt(
            ref_audio=ref_audio,
            ref_text=config.get("ref_text"),
            preprocess_prompt=True,
        )

    num_step = int(config.get("num_step", 16))
    gen_config = OmniVoiceGenerationConfig(num_step=num_step)
    emit({"status": "model_ready", "device": device, "num_step": num_step})
    emit({"status": "job_start", "language": language, "count": len(segments)})

    done = cached = errors = 0
    for i, seg in enumerate(segments):
        out_path = seg["output"]
        Path(out_path).parent.mkdir(parents=True, exist_ok=True)
        if Path(out_path).exists() and Path(out_path).stat().st_size > 0:
            try:
                info = torchaudio.info(out_path)
                emit({"segment": i, "status": "cached",
                      "actual_duration": round(info.num_frames / info.sample_rate, 2)})
                cached += 1
                continue
            except Exception:
                pass

        kwargs = {"text": seg["text"], "language": language, "generation_config": gen_config}
        if prompt is not None:
            kwargs["voice_clone_prompt"] = prompt
        if seg.get("instruct"):
            kwargs["instruct"] = seg["instruct"]
        if seg.get("duration"):
            kwargs["duration"] = seg["duration"]
        if seg.get("speed"):
            kwargs["speed"] = seg["speed"]

        try:
            t0 = time.time()
            audios = model.generate(**kwargs)
            audio = audios[0]
            torchaudio.save(out_path, audio.cpu(), SAMPLE_RATE)
            emit({"segment": i, "status": "done",
                  "actual_duration": round(audio.shape[-1] / SAMPLE_RATE, 2),
                  "gen_time": round(time.time() - t0, 1), "language": language})
            done += 1
        except Exception as e:
            emit({"segment": i, "status": "error", "error": str(e)[:300]})
            errors += 1

    emit({"status": "complete", "total": done + cached,
          "done": done, "cached": cached, "errors": errors})


if __name__ == "__main__":
    main()
