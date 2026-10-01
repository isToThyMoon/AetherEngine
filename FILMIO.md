# Filmio modifications

This branch is AetherEngine 7.21.1 (`228e8e0f`) as used by the Filmio app, published to meet the
LGPL-3.0 requirement of providing the source of a modified version. Upstream:
<https://github.com/superuser404notfound/AetherEngine>. License unchanged, see `LICENSE`.

Every change is marked with a `Filmio:` comment. Modified since 2026-10-01:

- **Background park instead of teardown** (`AetherEngine.parkForBackground` / `unparkFromBackground`).
  On iOS, a paused native VOD session served from the loopback producer is no longer torn down when
  the app is backgrounded. Only the AVPlayer item (and with it the decode session) and the loopback
  listener are released; the producer, the segment cache and the source reader are kept, so a
  buffered title plays from cache on return and an unfinished one keeps filling from its frontier.
  Live, software-decoded and external-playback sessions keep the upstream teardown.
- `HLSLocalServer.start(preferredPort:)`: re-listen on the previous port; each start retires the
  previous accept loop.
- `HLSVideoEngine.suspendServing()` / `resumeServing(preferredPort:)`.
- `NativeAVPlayerHost.parkItemForBackground()`: detach the item, keep the published clock and state.
