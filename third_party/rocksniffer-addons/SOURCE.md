# RockSniffer addons

The overlay pages ("addons") of [RockSniffer](https://github.com/kokolihapihvi/RockSniffer) by
kokolihapihvi and contributors, copied unchanged from its `addons/` folder at commit
`6111f626ac7bc355e1325f48651907dd44f14977` (2025-11-15), except `config.js`: RS Companion
generates it with the port in use (`app/Sources/OverlayServer.swift`). MIT License, see
[LICENSE](LICENSE). The libraries in `_deps/` (jQuery, jQuery UI, Vue, obs-websocket-js, ...)
carry their own licenses in their headers.

`app/build.sh` copies this folder into the app; the app serves it at
`http://127.0.0.1:9938/addons/` when stream overlays are on.
