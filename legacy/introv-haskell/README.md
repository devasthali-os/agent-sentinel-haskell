# introv-haskell (legacy Servant demo)

This is the original, unrelated Servant demo that previously lived at the repo
root. It is **not** part of the `agent-sentinel` product and is **not** built
by the new package's `stack.yaml`. It is kept here for historical reference only.

It targets the ancient system toolchain (GHC 8.2.x / `cabal`), which has no
Apple Silicon (aarch64) bindist. Do not build it with the modern stack used by
the sentinel engine.

```
created using `cabal init`

$ ghc --version
The Glorious Glasgow Haskell Compilation System, version 8.2.1

$ cabal install
$ cabal run
Running introv-haskell...
Hello, Haskell!

$ curl -v localhost:8081/users
[{"email":"isaac@newton.co.uk", ...}, ...]
```

Haskell 101: https://github.com/prayagupd/currys-paradox.hs
