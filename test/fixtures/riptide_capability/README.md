# `fixture.wasm`

A hand-authored WASI Preview 2 component for `Riptide.Capability`'s test
suite (Phase 6b-i). Exports two functions:

- `greet(name: string) -> string` — a normal, fast-returning call, used
  for the success-path golden cases (both EffectCapability and
  ObserveCapability — this phase makes no behavioral distinction between
  the two kinds).
- `burn-fuel()` — an intentional infinite loop, used to exercise the
  fuel-exhaustion and timeout golden cases.

## Rebuilding

```bash
rustup target add wasm32-wasip2
cargo install cargo-component --version 0.21.1
cd /tmp && cargo component new --lib riptide_capability_fixture
```

Replace `wit/world.wit` with:

```wit
package component:riptide-capability-fixture;

world example {
    export greet: func(name: string) -> string;
    export burn-fuel: func();
}
```

Replace `src/lib.rs` with:

```rust
#[allow(warnings)]
mod bindings;

use bindings::Guest;

struct Component;

impl Guest for Component {
    fn greet(name: String) -> String {
        format!("Hello, {name}!")
    }

    fn burn_fuel() {
        let mut counter: u64 = 0;
        loop {
            counter = counter.wrapping_add(1);
            std::hint::black_box(counter);
        }
    }
}

bindings::export!(Component with_types_in bindings);
```

Then:

```bash
cargo component build --release
cp target/wasm32-wasip1/release/riptide_capability_fixture.wasm \
  <riptide-repo>/test/fixtures/riptide_capability/fixture.wasm
```
