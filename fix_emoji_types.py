with open('liveAPP/PIPContent.swift', 'r', encoding='utf-8') as f:
    content = f.read()

content = content.replace(
    'let emojiSize = msg.inlineEmojiSize ?? giftSizeLocal',
    'let emojiSize = (msg.inlineEmojiSize?.width ?? giftSizeLocal)'
)

with open('liveAPP/PIPContent.swift', 'w', encoding='utf-8') as f:
    f.write(content)

print('Fixed')
