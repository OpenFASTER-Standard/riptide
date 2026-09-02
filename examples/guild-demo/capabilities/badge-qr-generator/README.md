# `badge-qr-generator.wasm`

A hand-authored WASI Preview 2 component for the Sub-project 6 demo (Phase 6p-ii, beat 1 — "teach
Riptide its first trick"). Exports one function:

- `generate-qr-code(text: string) -> string` — encodes `text` (the demo visitor's own free-text
  content, extracted by LLMFallback from their Task submission) as a QR code, returned as a
  self-contained SVG string.

## Rebuilding

```bash
rustup target add wasm32-wasip2
cargo install cargo-component --version 0.21.1
cd /tmp && cargo component new --lib badge_qr_generator
```

Replace `wit/world.wit` with:

```wit
package component:guild-demo-badge-qr-generator;

world example {
    export generate-qr-code: func(text: string) -> string;
}
```

From inside `badge_qr_generator/`, add the QR-encoding dependency:

```bash
cargo add qrcode --no-default-features --features svg
```

Replace `src/lib.rs` with:

```rust
#[allow(warnings)]
mod bindings;

use bindings::Guest;
use qrcode::render::svg;
use qrcode::QrCode;

struct Component;

impl Guest for Component {
    fn generate_qr_code(text: String) -> String {
        let code = QrCode::new(text.as_bytes()).unwrap();
        code.render()
            .min_dimensions(200, 200)
            .dark_color(svg::Color("#000000"))
            .light_color(svg::Color("#ffffff"))
            .build()
    }
}

bindings::export!(Component with_types_in bindings);
```

Then:

```bash
cargo component build --release
cp target/wasm32-wasip1/release/badge_qr_generator.wasm \
  <riptide-repo>/examples/guild-demo/capabilities/badge-qr-generator/badge-qr-generator.wasm
```
