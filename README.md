# K.A.R.E.N.
### Knowledge Adaptive Responsive Electronic Navigator

A voice-first AI personal assistant for macOS with a procedural neural orb UI, hand gesture control, and a Python LLM sidecar.

---

## Download the Mac app

Open the repository's **Releases** page and download the installer matching the
Mac: `K.A.R.E.N.-macos-arm64.dmg` for Apple silicon, or
`K.A.R.E.N.-macos-x86_64.dmg` for Intel. Open the disk image and drag
`K.A.R.E.N.` into Applications. The download bundles the Python voice service;
users do not need to install Python, Swift, Xcode, or run setup commands.

The public build is not signed or notarized with an Apple Developer ID. On its
first launch, Control-click the app in Applications, choose **Open**, and
confirm once. macOS will request microphone and speech-recognition access; the
camera is requested only when gesture controls are enabled.

## Build from source

```bash
# 1. Clone and enter
cd K.A.R.E.N.

# 2. Setup (creates venv, installs deps, runs tests, builds Swift)
bash scripts/setup.sh

# 3. Run
bash scripts/run.sh
```

GitHub Actions builds separate Apple silicon and Intel installers when a `v*`
version tag is pushed. You can also create the same local installers on a Mac
with Python 3.13 by installing `pyinstaller` into `sidecar/.venv` and running
`bash scripts/package_app.sh`.

**System requirements:**
- macOS 15+ (tested on macOS 27.0.1 / Apple M5)
- Swift 6.0+ (Apple Swift version 6.4 installed)
- Python 3.13.x (`python3 --version`) to build from source; downloaded apps
  include their Python runtime
- Xcode.app for Metal rendering (optional — Canvas renderer works without it)

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    KarenApp (Swift)                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   SwiftUI     │  │ Metal / Canvas│  │  Menu Bar    │  │
│  │  ContentView  │  │   OrbView    │  │    Extra     │  │
│  └──────┬───────┘  └──────────────┘  └──────────────┘  │
│         │                                                │
│  ┌──────▼───────────────────────────────────────────┐   │
│  │                  KarenCore                        │   │
│  │  OrbState · AudioLevel · Permissions · Controls  │   │
│  └──────┬────────────────┬──────────┬───────────────┘   │
│         │                │          │                    │
│  ┌──────▼──────┐  ┌──────▼──────┐  ┌▼─────────────┐    │
│  │SpeechEngine │  │GestureProc. │  │SidecarBridge │    │
│  │WakeWordDet. │  │(VNHandPose) │  │(Unix WebSocket│    │
│  │TTSEngine    │  │             │  │+ Proc mgmt)  │    │
│  └─────────────┘  └─────────────┘  └──────┬───────┘    │
└────────────────────────────────────────────┼────────────┘
                                             │ 127.0.0.1:18765
                                             │ WebSocket JSON
                        ┌────────────────────▼──────────────┐
                        │       karen_sidecar (Python 3.13)  │
                        │  ┌──────────┐  ┌──────────────┐   │
                        │  │ LLM Client│  │ Intent Router │   │
                        │  │(Mock/OAII)│  │  + Skills    │   │
                        │  └──────────┘  └──────────────┘   │
                        │  ┌──────────────────────────────┐  │
                        │  │  SQLite Memory (approval-gated)│  │
                        │  └──────────────────────────────┘  │
                        └───────────────────────────────────┘
```

---

## Socket Protocol

All messages are JSON over a WebSocket bound to localhost (`127.0.0.1:18765`).

### Shell → Sidecar

| Message | Fields | Description |
|---------|--------|-------------|
| `transcript` | `id`, `text`, `final` | Recognised speech utterance |
| `ping` | — | Keepalive |
| `cancel` | `id` | Cancel in-flight request |

### Sidecar → Shell

| Message | Fields | Description |
|---------|--------|-------------|
| `state` | `state` | Orb state transition |
| `reply` | `id`, `text`, `speak`, optional `speech_text` | Displayed reply and optional separate text for TTS |
| `action` | `id`, `skill`, `payload`, `needs_confirm` | Skill action (may need confirmation) |
| `error` | `id`, `message` | Error |
| `pong` | — | Ping response |

**OrbState values:** `idle` · `listening` · `processing` · `speaking` · `permission` · `error`

---

## Arithmetic, logic, and web search

K.A.R.E.N. routes arithmetic and Boolean expressions to local, safe parsers. It
supports spoken numbers, decimals, negative numbers, common functions, standard
operator precedence, comparisons, Boolean operators, and truth tables. Invalid
or incomplete calculations receive a clarification prompt. Search requests use
Brave Search or Tavily; the assistant shows result titles and source URLs while
speaking only a short summary. Tavily's free plan is available from Settings,
where its key is stored in macOS Keychain.

To use free web search, create a Tavily key and add it under **Settings > Free
Web Search**. Tavily currently includes 1,000 monthly credits on its free plan;
basic searches cost one credit. The key is stored in macOS Keychain and takes
effect immediately. Brave Search remains available for users who already have
a Brave API key.

When launching from source, Brave can also be configured in the environment:

```bash
export KAREN_SEARCH_PROVIDER=brave
export KAREN_BRAVE_API_KEY='your-api-key'
export KAREN_SEARCH_COUNTRY=IN
export KAREN_SEARCH_LANG=en
bash scripts/run.sh
```

The key stays in the process environment and should not be committed to the
repository. Without a provider and key, K.A.R.E.N. says search is unavailable
and does not claim it searched. A configured real LLM can summarize retrieved
snippets and use the latest search context for follow-up questions. The default
offline MockLLM cannot provide open-ended knowledge or generate contextual
follow-up answers; local math and logic continue to work offline.

Supported settings: `KAREN_SEARCH_PROVIDER=brave`, `KAREN_BRAVE_API_KEY`,
`KAREN_SEARCH_COUNTRY` (default `IN`), and `KAREN_SEARCH_LANG` (default `en`).

## Text, voice, and image inputs

The message box accepts typed questions, the microphone sends its recognized
transcript, and **Image** lets you choose a picture. Image classification uses
macOS Vision on the Mac; the picture itself is not sent to the sidecar or web
service. Ask “What is this?” after selecting it to hear the most likely label.
Labels are estimates, so use a clear image and treat uncertain results as
suggestions. A photo classifier does not determine a person's identity.

On first launch, K.A.R.E.N. creates a personal editable copy at
`~/Library/Application Support/KAREN/input_sources.json` from the template
[`sidecar/data/input_sources.json`](sidecar/data/input_sources.json). Add
user-provided facts and object descriptions there. For example, `facts` entries
can contain `triggers` and an `answer` for questions such as “Who are my
friends?”; `objects` entries can contain `tags` and a `description` for
classifier labels you want K.A.R.E.N. to explain. Keep the file to information
you choose to provide. You can point to another JSON file with
`KAREN_INPUT_FILE` before launching from source.

```json
{
  "version": 1,
  "facts": [
    { "triggers": ["my friends"], "answer": "Your friends are <names you provide>." }
  ],
  "objects": [
    { "tags": ["cat", "tabby"], "description": "This is my cat, <name you provide>." }
  ]
}
```

---

## Orb States — Visual Design

| State | Motion | Shape | Icon/Label |
|-------|--------|-------|------------|
| **idle** | Slow breathing (radius oscillates ±2%) | All shells present, rings orbit slowly | `sparkle` |
| **listening** | Shells tighten toward equator, pulse with audio level | Compressed sphere | `mic.fill` |
| **processing** | Filaments flow inward, rings spin 3× faster | Collapsing shell | `circle.dotted` |
| **speaking** | Waveform ripples across outer shell | Wave-deformed sphere | `waveform` |
| **permission** | Rings lock (no rotation), gentle inner circles | Rigid ring | `lock.fill` |
| **error** | Broken-ring gap, flickering fill | Red-tinted, arc gap | `exclamationmark.triangle.fill` |

> States differ by **motion + shape + icon**, never by color alone (WCAG AA).

---

## Renderers

| Renderer | When active | Notes |
|----------|-------------|-------|
| **Canvas** (SwiftUI) | `swift build` / any machine | 60 fps via `TimelineView`. Uses Fibonacci sphere distribution, FBM noise, all 6 states. |
| **Metal** (MTKView) | Xcode.app build | GPU-instanced. 8 192 filament points. Same shader math. Requires `metal` compiler. |

---

## Entitlements & Permissions

| Permission | Entitlement | Why | When active |
|------------|-------------|-----|-------------|
| Microphone | `com.apple.security.device.audio-input` | Voice input + wake word | While listening / wake word on |
| Camera | `com.apple.security.device.camera` | Hand gesture tracking | Gesture mode only |
| Speech Recognition | `com.apple.security.personal-information.speech-recognition` | On-device STT | While listening |
| Network client | `com.apple.security.network.client` | Optional remote LLM | Only if configured |
| User files | `com.apple.security.files.user-selected.read-write` | Future file skills | Not yet used |

All permissions explained in the in-app **Permissions Center** before requesting.

---

## LLM Configuration

K.A.R.E.N. defaults to offline **MockLLM** (no key needed, no network). To use a real LLM:

```bash
export KAREN_LLM_PROVIDER=openai
export KAREN_LLM_KEY=sk-...              # stored in Keychain in production
export KAREN_LLM_MODEL=gpt-4o-mini
export KAREN_LLM_BASE_URL=https://api.openai.com/v1  # or Ollama: http://localhost:11434/v1
swift run KarenApp
```

---

## Tests

```bash
cd sidecar
.venv/bin/python3 -m pytest tests/ -v
```

**97 tests, 0 failures** (verified 2026-10-16):
- `test_protocol.py` — 6 tests: message parsing, serialisation
- `test_llm_router.py` — 5 tests: MockLLM cycling, skill routing
- `test_memory.py` — 5 tests: propose/approve/delete/context
- `test_gesture_math.py` — 12 tests: pinch zoom, rotation delta, clamping
- `test_math_engine.py` — safe arithmetic, spoken parsing, Decimal precision, limits
- `test_logic_engine.py` — Boolean expressions, comparisons, truth tables
- `test_intelligence.py` — intent classification, Brave API and search errors

---

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Toggle listening | ⌘L |
| Toggle mute | ⌘M |
| Stop speaking | ⌘. |
| Permissions Center | ⇧⌘P |
| Settings | ⌘, |
| Dismiss dialogs | Esc |

---

## Feasibility Table

| Feature | Status | Notes |
|---------|--------|-------|
| Metal orb (6 states) | **Partial** | Canvas renderer verified; Metal shaders written but need Xcode.app |
| SwiftUI Canvas orb | **Verified** | 60 fps, all 6 states, LOD, reduce motion |
| Python sidecar + WebSocket | **Verified** | Localhost socket, typed protocol, mock LLM |
| MockLLM offline mode | **Verified** | 97 Python tests pass |
| Local arithmetic and logic | **Verified** | Safe parsers, spoken expressions, truth tables |
| Tavily and Brave web search | **Implemented** | Tavily free tier available; both require a key and network access |
| On-device STT (SFSpeechRecognizer) | **UNVERIFIED** | Code written; needs mic permission at runtime |
| TTS (AVSpeechSynthesizer) | **UNVERIFIED** | Code written; needs audio output at runtime |
| Wake word ("Karen") | **UNVERIFIED** | SFSpeechRecognizer loop written; needs runtime test |
| Hand tracking (VNDetectHumanHandPoseRequest) | **UNVERIFIED** | Code written; needs camera + runtime test |
| Menu bar agent | **UNVERIFIED** | Code written; needs signed .app to run as agent |
| Permissions Center UI | **Verified** | All views render; actual grants need runtime |
| Memory (SQLite, approval-gated) | **Verified** | 5 memory tests pass |
| Phone pairing | **Not implemented (Phase 7)** | Planned: Bonjour + WebSocket + pairing code |
| Real LLM (OpenAI-compatible) | **UNVERIFIED** | Client written; needs API key |
| GPU instancing (filaments) | **Partial** | Metal shader written; Canvas uses CPU loop (800–2000 pts) |

---

## Project Structure

```
karen/
├── Package.swift                      # Swift Package Manager
├── .python-version                    # 3.13.13
├── scripts/
│   ├── setup.sh                       # One-command setup
│   └── run.sh                         # Launch script
├── KarenApp/
│   ├── Resources/
│   │   └── KarenApp.entitlements
│   └── Sources/
│       ├── App/
│       │   ├── KarenApp.swift         # @main, MenuBarExtra, commands
│       │   └── KarenCore.swift        # Central observable state
│       ├── Metal/
│       │   ├── Orb.metal              # GPU shaders (Xcode only)
│       │   ├── OrbRenderer.swift      # MTKView delegate
│       │   ├── OrbCanvasView.swift    # SwiftUI Canvas renderer (active)
│       │   └── OrbView.swift          # Routes Metal ↔ Canvas
│       ├── Views/
│       │   ├── ContentView.swift      # Main window + HUD
│       │   ├── MenuBarContent.swift   # Menu bar extra
│       │   └── SettingsView.swift     # Settings, Permissions, Memory
│       ├── Speech/
│       │   ├── SpeechEngine.swift     # STT + TTS
│       │   └── WakeWordDetector.swift # Continuous wake-word loop
│       ├── Gestures/
│       │   └── GestureProcessor.swift # VNHandPose → orb transforms
│       └── Sidecar/
│           └── SidecarBridge.swift    # Process mgmt + WebSocket client
└── sidecar/
    ├── pyproject.toml
    ├── karen_sidecar/
    │   ├── protocol.py                # Typed message schema (Pydantic)
    │   ├── llm.py                     # Pluggable LLM (Mock / OpenAI)
    │   ├── memory.py                  # SQLite approval-gated memory
    │   ├── router.py                  # Intent router + skill registry
    │   └── server.py                  # WebSocket server (localhost)
    └── tests/
        ├── test_protocol.py
        ├── test_llm_router.py
        ├── test_memory.py
        └── test_gesture_math.py
```

---

## What Works · What Doesn't · What's Next

### ✅ Works (verified)
- 28 Python unit tests pass (protocol, LLM, memory, gesture math)
- Full Swift app compiles with `swift build`
- SwiftUI Canvas orb: all 6 states, LOD, stars, rings, glow
- Python sidecar: typed WebSocket protocol, MockLLM, intent routing, memory
- All UI views: Settings, Permissions Center, Memory, HUD, menu bar

### ⚠️ Written but not runtime-verified
- STT/TTS/wake word — requires mic grant + audio output (needs `.app` bundle with entitlements)
- Hand tracking — requires camera grant + Continuity Camera or built-in camera access
- Metal shaders — require Xcode.app (`metal` compiler absent from CLI tools)

### 🔜 Next (Phase 7–8)
- Phone pairing: Bonjour + WebSocket + pairing code + iOS companion stub
- Real LLM integration: end-to-end test with OpenAI-compatible API
- Xcode project (`.xcodeproj`) for full Metal + sandbox entitlements
- Polish: accessibility audit, performance profiling, screenshots

---

*Built on macOS 27.0.1 · Apple M5 · Swift 6.4 · Python 3.13.13 · Metal 4*
