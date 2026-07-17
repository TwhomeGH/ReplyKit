import re

with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\ReplyKIT\VideoProcess.swift', 'rb') as f:
    raw = f.read()

# Normalize line endings
c = raw.replace(b'\r\r\n', b'\r\n').replace(b'\r\n', b'\n')

text = c.decode('utf-8')

# 1. Add properties after processingGeneration
text = text.replace(
    '    private var processingGeneration: UInt64 = 0',
    '    private var processingGeneration: UInt64 = 0\n    private let videoQueue = DispatchQueue(label: "com.replykit.video", qos: .userInitiated)\n    private weak var videoTaskChain: Task<Void, Never>?',
    1
)

# 2. Remove isProcessing and related vars (keep processingGeneration)
text = text.replace(
    '    private var isProcessing = false\n    private var processingStartedAt: Date?\n    private let processingTimeout: TimeInterval = 2.0\n    private var watchdogResetCount: Int = 0\n    private var consecutiveDropCount: Int = 0\n    private let maxConsecutiveDrops = 60\n    private var processingGeneration: UInt64 = 0',
    '    private var processingStartedAt: Date?\n    private let processingTimeout: TimeInterval = 2.0\n    private var watchdogResetCount: Int = 0\n    private var consecutiveDropCount: Int = 0\n    private let maxConsecutiveDrops = 60\n    private var processingGeneration: UInt64 = 0',
    1
)

# 3. Fix the log line that references isProcessing
text = text.replace(
    'sendlog("[VProc] #\\(localCount) PTS:\\(String(format:"%.3f",pts.seconds))s active:\\(isActive) processing:\\(isProcessing)")',
    'sendlog("[VProc] #\\(localCount) PTS:\\(String(format:"%.3f",pts.seconds))s active:\\(isActive)")',
    1
)

# 4. Remove the old watchdog block
old_watchdog_pattern = r'        // Watchdog: .*?\n        if isProcessing, let startedAt = processingStartedAt \{\n            if Date\(\)\.timeIntervalSince\(startedAt\) > processingTimeout \{\n                isProcessing = false\n                processingStartedAt = nil\n                watchdogResetCount \+\= 1\n                resetProcessorActor\(\n                    reason: ".*?"\n                \)\n            \}\n        \}\n\n        // .*?\n        if watchdogResetCount > 3 \{'

text = re.sub(old_watchdog_pattern, '        if watchdogResetCount > 3 {', text, 1, re.DOTALL)

# 5. Find and replace the old isProcessing guard + Task.detached block
old_task_marker = '        guard !isProcessing else { return }'
new_start = '        videoQueue.async { [weak self] in\n            guard let self else { return }\n            let prev = self.videoTaskChain\n            self.videoTaskChain = Task(priority: .high) { [weak self] in\n                _ = await prev?.value\n                guard let self, self.isActive else { return }'

if old_task_marker in text:
    # Find the start of the block
    start_idx = text.index(old_task_marker)
    
    # Find the end of the Task.detached block
    # The block ends with a closing brace at the right indent level
    task_detached_end = text.index('Task.detached(priority: .utility)', start_idx)
    # Find the closing brace of the Task.detached block
    brace_count = 0
    end_idx = task_detached_end
    for i in range(task_detached_end, len(text)):
        if text[i] == '{':
            brace_count += 1
        elif text[i] == '}':
            brace_count -= 1
            if brace_count == 0:
                end_idx = i + 1  # Include the closing brace
                break
    
    # Find the content between start and end
    old_block = text[start_idx:end_idx]
    
    # Find matching content after the new prefix (from the same method)
    # We need to copy the body from old_block but without the isProcessing guard
    body_start = text.index('let isFirstFrame', start_idx)
    rest_of_body = text[body_start:end_idx]
    
    new_block = new_start + '\n\n' + rest_of_body + '\n            }\n        }'
    
    text = text[:start_idx] + new_block + text[end_idx:]
    print('OK - replaced')
else:
    print('NOT FOUND')
    # Find the second occurrence
    idx = text.find('actor.processFrame')
    print(f'actor.processFrame at {idx}')
    idx2 = text.find('actor.processFrame', idx + 1)
    print(f'Second at {idx2}')
    if idx2 >= 0:
        print(f'Context: {text[idx2-100:idx2+100]}')

with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\ReplyKIT\VideoProcess.swift', 'wb') as f:
    f.write(text.encode('utf-8').replace(b'\n', b'\r\n'))
print('done')
