# `curse.wasm`

A hand-authored WASI Preview 2 component for the Sub-project 6 demo (Phase 6p-ii, beat 2 — teaching
Riptide a second, deliberately-broken capability). Exports one function:

- `curse()` — panics immediately. Deliberately different from
  `test/fixtures/riptide_capability/fixture.wasm`'s own `burn-fuel()` (an infinite loop that trips
  fuel-exhaustion/timeout, `Riptide.Capability`'s `:resource_exhausted` classification): an immediate
  panic instead lands in `Riptide.Capability`'s `{:error, {:trap, output}}` branch and fails within
  milliseconds rather than waiting out a fuel/timeout window — see
  `docs/superpowers/specs/2026-09-02-phase-6p-ii-demo-wasm-components-design.md` §3 for the full
  reasoning.

## Rebuilding

```bash
rustup target add wasm32-wasip2
cargo install cargo-component --version 0.21.1
cd /tmp && cargo component new --lib curse_component
```

Replace `wit/world.wit` with:

```wit
package component:guild-demo-curse;

world example {
    export curse: func();
}
```

Replace `src/lib.rs` with:

```rust
#[allow(warnings)]
mod bindings;

use bindings::Guest;

struct Component;

impl Guest for Component {
    fn curse() {
        panic!("the chest is cursed");
    }
}

bindings::export!(Component with_types_in bindings);
```

Then:

```bash
cargo component build --release
cp target/wasm32-wasip1/release/curse_component.wasm \
  <riptide-repo>/examples/guild-demo/capabilities/curse/curse.wasm
```
