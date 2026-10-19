"""Normalize typed, transcribed speech, image labels, and user supplied facts."""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any


if getattr(sys, "frozen", False):
    TEMPLATE_INPUT_FILE = Path(getattr(sys, "_MEIPASS", ".")) / "data" / "input_sources.json"
else:
    TEMPLATE_INPUT_FILE = Path(__file__).resolve().parent.parent / "data" / "input_sources.json"
DEFAULT_INPUT_FILE = Path.home() / "Library" / "Application Support" / "KAREN" / "input_sources.json"
_IMAGE_QUESTION = re.compile(r"\b(what is this|what am i showing|describe (?:this|the image|the picture)|what can you see)\b", re.I)
_PERSON_QUESTION = re.compile(r"\b(who is this|who is in (?:this|the picture|the image)|who am i showing)\b", re.I)
_FRIENDS_QUESTION = re.compile(r"\b(who are all my friends|who are my friends|name my friends|list my friends)\b", re.I)


class InputAdapter:
    """Join voice/text transcripts and image-classifier labels to user knowledge."""

    def __init__(self, source_file: str | Path | None = None):
        configured = source_file or os.environ.get("KAREN_INPUT_FILE")
        self.source_file = Path(configured) if configured else DEFAULT_INPUT_FILE
        if configured is None and not self.source_file.exists():
            try:
                self.source_file.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(TEMPLATE_INPUT_FILE, self.source_file)
            except OSError as exc:
                print(f"[input] Could not initialize personal input file: {type(exc).__name__}")

    def load_sources(self) -> dict[str, Any]:
        try:
            payload = json.loads(self.source_file.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {"facts": [], "objects": []}
        except (OSError, json.JSONDecodeError) as exc:
            print(f"[input] Could not load knowledge file: {type(exc).__name__}")
            return {"facts": [], "objects": []}
        if not isinstance(payload, dict):
            return {"facts": [], "objects": []}
        return {
            "facts": payload.get("facts", []) if isinstance(payload.get("facts", []), list) else [],
            "objects": payload.get("objects", []) if isinstance(payload.get("objects", []), list) else [],
        }

    @staticmethod
    def normalize(text: str, image_labels: list[str] | None = None) -> dict[str, Any]:
        labels = [label.strip()[:120] for label in (image_labels or [])
                  if isinstance(label, str) and label.strip()][:8]
        return {"text": text.strip()[:4_000], "image_labels": labels}

    def answer_local(self, text: str, image_labels: list[str] | None = None) -> str | None:
        normalized = re.sub(r"\s+", " ", text).strip()
        sources = self.load_sources()

        if _FRIENDS_QUESTION.search(normalized):
            for fact in sources["facts"]:
                if not isinstance(fact, dict):
                    continue
                triggers = fact.get("triggers", [])
                if isinstance(triggers, list) and any(
                    isinstance(item, str) and item.strip().lower() in normalized.lower()
                    for item in triggers
                ) and isinstance(fact.get("answer"), str) and fact["answer"].strip():
                    return fact["answer"].strip()
            return None

        labels = [item.strip() for item in (image_labels or []) if isinstance(item, str) and item.strip()]
        if not labels:
            return None
        if _PERSON_QUESTION.search(normalized):
            if any("person" in label.lower() or "face" in label.lower() for label in labels):
                return "I can see a person, but the image labels cannot tell me their name. If you tell me who they are, I can add that fact to your input file."
            return "I don’t see a clear person label in the selected image."
        # Optional user descriptions enrich local classifier labels without
        # treating filenames or unverified model guesses as ground truth.
        for item in sources["objects"]:
            if not isinstance(item, dict):
                continue
            tags = item.get("tags", [])
            description = item.get("description")
            if (isinstance(tags, list) and isinstance(description, str)
                    and any(isinstance(tag, str) and any(tag.lower() in label.lower() for label in labels)
                            for tag in tags)):
                return description.strip()
        if _IMAGE_QUESTION.search(normalized):
            top = labels[0].replace("_", " ").strip()
            return f"This looks like {article_for(top)}{top}."
        return None

    def context_for(self, image_labels: list[str] | None = None) -> str:
        labels = [label.strip() for label in (image_labels or []) if isinstance(label, str) and label.strip()]
        if not labels:
            return ""
        return "Selected image classifier labels (not guaranteed): " + ", ".join(labels[:8])


def article_for(phrase: str) -> str:
    """Return a/an for a short displayed classifier label."""
    return "an " if phrase[:1].lower() in "aeiou" else "a "
