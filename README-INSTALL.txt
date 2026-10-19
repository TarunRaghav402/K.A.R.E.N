K.A.R.E.N. for macOS

INSTALL
1. Open the downloaded ZIP to extract K.A.R.E.N.
2. Move K.A.R.E.N. to your personal Applications folder:
   ~/Applications (inside your home folder). Create that folder if needed.
   macOS may ask for a password when copying to the system-wide /Applications
   folder; cancel that prompt and use ~/Applications instead. K.A.R.E.N. does
   not need administrator access.
3. Open K.A.R.E.N. from ~/Applications or Spotlight.
4. Allow microphone and speech recognition when macOS asks. Allow camera only
   if you turn on hand gesture controls.

The download includes its Python voice service. You do not need to install
Python, Swift, Xcode, or run setup commands.

FIRST OPEN AND macOS SECURITY
The public build uses a hardened runtime signature, but it is not signed or
notarized with an Apple Developer ID. macOS may show a security warning. It
should not ask for your Mac administrator password to open: K.A.R.E.N. does
not need administrator access. Do not enter a password into an unexpected
prompt. A password prompt while copying into /Applications comes from macOS
protecting the system-wide Applications folder; use ~/Applications instead.

To approve the app, open System Settings > Privacy & Security and choose
"Open Anyway" for K.A.R.E.N., then open it again and confirm. You can also
Control-click K.A.R.E.N. in Applications, choose Open, then confirm Open.
Only install copies you downloaded from the project release source you trust.

AI
The app includes its offline assistant. Connecting an online AI provider is
optional and requires configuring a provider and API key separately.
