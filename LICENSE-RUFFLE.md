# Ruffle licensing note

The files under `ruffle/patches/` and `ruffle/optional/` are patches against the Ruffle source tree. They are derived works of Ruffle, which is licensed under MIT OR Apache-2.0 (your choice). The patches stay under Ruffle's licence, and the authorship in each patch header is kept intact. The rest of this repository (scripts, tools, templates, documentation) is under the MIT licence in `LICENSE`.

## When you redistribute a binary

A `ruffle_sdl` binary you build from the pinned commit plus these patches contains Ruffle and many third party Rust crates. When you ship it (for example in a PortMaster zip):

* include Ruffle's own licence texts (MIT and Apache 2.0),
* include the licence texts of the linked crates,
* keep them in a `licenses/` folder next to the port, as flat files such as `licenses/LICENSE.ruffle.txt`.

Generate the combined text with `ruffle/make_licenses.py`. It walks the dependency tree of the patched source (through `cargo metadata`) and writes one file with every crate's licence. Run it against the same tree you built the binary from, and regenerate it when the pin changes.

The upstream project: https://github.com/ruffle-rs/ruffle

## Not covered by this note

Flash and AIR games you port are not part of this repository and are not licensed by it. Bring your own game files and ship code and deltas only.
