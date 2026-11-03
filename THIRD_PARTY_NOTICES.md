# Third-party components

terminal-phone doesn't bundle these components in its source or release archives. `terminal-phone setup` and `terminal-phone connect` download them onto your Mac, pinned by SHA-256, and each stays under its own license.

| Component | Used for | License |
|---|---|---|
| [idb / idb_companion](https://github.com/facebook/idb) and the `fb-idb` client | Simulator video, input and accessibility | MIT |
| [WebDriverAgent](https://github.com/appium/WebDriverAgent) | Real-iPhone control, built and signed locally with your team | BSD-3-Clause |
| [python-build-standalone](https://github.com/astral-sh/python-build-standalone) | Private Python runtime for the idb client | CPython: PSF License; build tooling: MPL-2.0 |
| [grpclib](https://github.com/vmagamedov/grpclib) | gRPC transport for idb | BSD-3-Clause |
| [protobuf](https://github.com/protocolbuffers/protobuf) | Message encoding for idb | BSD-3-Clause |
| [aiofiles](https://github.com/Tinche/aiofiles) | idb client dependency | Apache-2.0 |
| [multidict](https://github.com/aio-libs/multidict) | grpclib dependency | Apache-2.0 |
| [h2](https://github.com/python-hyper/h2), [hpack](https://github.com/python-hyper/hpack), [hyperframe](https://github.com/python-hyper/hyperframe) | HTTP/2 for grpclib | MIT |

Apple's Xcode, simulators, `simctl` and `devicectl` are used as installed on your Mac and are covered by Apple's terms.
