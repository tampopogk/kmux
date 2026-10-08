# kmux

A native macOS terminal multiplexer: windows of tabs, split into Ghostty
terminal, web and iOS Simulator panes (markdown panes are coming), driven from the keyboard, the mouse, the `kmux` CLI
or anything that speaks its control protocol.

| Path | What |
|------|------|
| `docs/kmux-spec.md` | The spec, illustrated from the reference model. |
| `reference/kmux/` | The reference model: an interactive mockup (`index.html`) over a DOM-free core (`core.js`). |
| `tests/kmux-protocol/` | Protocol cases shared by the model and the app. |
| `apps/kmux/` | The app (Swift, AppKit, upstream Ghostty). |
| `crates/kmux/` | The `kmux` CLI (Rust). |
| `crates/kmux-client/` | Control-socket client, also used by kanna. |
| `crates/kmux-bench/`, `bench/` | The performance reference and its targets. |

```sh
scripts/build-kmux.sh            # target/kmux.app (builds GhosttyKit first if needed)
cargo build --release            # target/release/kmux
scripts/test-kmux-protocol.sh    # shared cases: model and app
scripts/e2e-kmux.sh              # end to end: app + CLI + pixels (KMUX_E2E_IOS=0 skips the simulator)
target/release/kmux-bench        # performance: pane start, typing latency, memory (targets in bench/)
```

Run several kmux instances at once with `kmux --instance NAME …` (each has
its own windows and socket); `kmux instances` lists them. Scripts and tests
can start kmux with `--bg` (app or CLI, or `KMUX_BG=1`) to keep it behind your other windows.

iOS panes need Xcode with an iOS simulator runtime:
`kmux open ios --app build/MyApp.app --device "iPhone 16"` (or a bundle ID
such as `com.apple.Preferences`).

## License

MIT. See [LICENSE](LICENSE).
