with open('liveAPP/PIPM_edit.swift','r',encoding='utf-8') as f:
    c = f.read()

# Change blend mode back to sourceAlpha for non-premultiplied rendering
c = c.replace(
    "pDesc.colorAttachments[0].sourceRGBBlendFactor = .one\n        pDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha\n        pDesc.colorAttachments[0].sourceAlphaBlendFactor = .one\n        pDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha",
    "pDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha\n        pDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha\n        pDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha\n        pDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha"
)

# Change bitmap context to use non-premultiplied alpha (.last instead of .first)
c = c.replace(
    "bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue",
    "bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue"
)

# Change texture creation to use non-premultiplied format
c = c.replace(
    "let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)",
    "let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)"
)

with open('liveAPP/PIPM_edit.swift','w',encoding='utf-8') as f:
    f.write(c)
print('Done')
