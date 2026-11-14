# todo-api: Titan test project

A small Express + SQLite API used to exercise Titan end to end. It uses
`better-sqlite3`, a native module whose compiled binary differs between macOS and
Linux. That's exactly the kind of dependency that produces "works on my machine" bugs.

```sh
titan up                      # creates the VM, installs deps inside it
titan run -- npm test         # tests run on Linux, not macOS
titan run -- npm start        # then: curl localhost:3000/health
```

`/health` reports the platform the code is actually running on.
