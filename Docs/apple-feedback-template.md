# Apple Feedback Assistant 回報模板

## Title (標題)
```
iOS 27 beta (24A5370h): Swift concurrency cooperative thread stack overflow (bug_type 309) on all QoS levels — 544KB stack too small for app extension setup
```

## Description (描述)

### What happened
App extension (Broadcast Upload Extension) crashes with `EXC_BAD_ACCESS / SIGBUS / KERN_PROTECTION_FAILURE` within ~500ms of launch, every time. All crashes are `bug_type: 309` (stack overflow).

### Why 544KB?
Swift concurrency cooperative threads on iOS use a **default stack of 0x88000 bytes (544KB = 512KB usable + 32KB guard/alignment)**. This is defined in the Swift runtime and is **not configurable** by the application.

For comparison:
- Main thread: 1MB+ (can grow dynamically)
- pthread default: 512KB
- Cooperative pool: 544KB (hard-capped, cannot grow)

### Affected QoS levels (ALL have cooperative variants)
| QoS | Cooperative Queue Name |
|-----|------------------------|
| `.userInitiated` | `com.apple.root.user-initiated-qos.cooperative` |
| `.utility` | `com.apple.root.utility-qos.cooperative` |
| `.background` | `com.apple.root.background-qos.cooperative` |

### What we tried (すべて失敗)
1. `Task.detached(priority: .userInitiated)` — moved to cooperative pool anyway
2. `Task(priority: .utility)` — moved to `utility-qos.cooperative` (still 544KB)
3. `DispatchQueue.global().async { Task { } }` — Swift runtime still assigns QoS-based cooperative pool
4. `Task.detached(priority: .background)` — `background-qos.cooperative` exists too
5. Split setup into multiple `Task.detached` with `.value` — each task independently overflows

### Root cause
Our extension's startup sequence calls into HaishinKit (RTMP streaming library), which uses actors with async/await. The setup phase involves 5+ actor hops with nested async calls:
```
broadcastStarted → configureVideo → configureAudio → configureMediaMixer
  → MediaMixer.startRunning() → RTMPStream.publish() → RTMPConnection.connect()
```
Each step creates internal `Task { }` within actors, creating deep continuation chains. Even when each major call is isolated in its own `Task.detached`, the internal actor call chains within HaishinKit alone exceed 544KB.

### Expected behavior
Cooperative threads should have **at least 1MB stack** (matching non-cooperative global concurrent pool), or cooperative scheduling should be **opt-in per QoS level** (not mandatory for all QoS).

### Attachments
8 crash logs (.ips files) showing:
- Consistent ~450-500ms time-to-crash
-`bug_type: 309`on all three QoS levels
- Stack guard page hit at exactly 16368 bytes into 16KB guard (consistent overflow pattern)

## Classification
- **Area**: Swift Concurrency / Runtime
- **Type**: Bug / Crash

## 建議的修復方向 (Suggested Fix)
1. Increase cooperative thread default stack from 544KB to 1MB+ on iOS (matching other platforms)
2. Or: make cooperative scheduling opt-in per QoS `userInitiated`, with `.default`/`.utility`/.`background` falling back to non-cooperative pool
3. Or: allow `Task` priority to explicitly opt OUT of cooperative scheduling
