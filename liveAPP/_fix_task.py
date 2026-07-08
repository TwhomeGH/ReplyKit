path = 'liveAPP/PIPService.swift'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

content = content.replace(
    '''                Task {
                    Task { @MainActor in
                        await self.renderIncremental()
                    }
                }''',
    '''                Task { @MainActor in
                    await self.renderIncremental()
                }'''
)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print('done')
