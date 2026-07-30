#!/usr/bin/env python3
# Add liveAPPWidget extension target to pbxproj

import re, sys

PBXPROJ = 'liveAPP.xcodeproj/project.pbxproj'

U = {}
def uid(key, val=None):
    if val is None:
        return U[key]
    U[key] = val
    return val

uid('LW_REF',      'CE281B212E5ACD670023BBC4')
uid('LW_TARGET',   'CE281B282E5ACD670023BBC4')
uid('LW_PRODUCT',  'CE281B292E5ACD670023BBC4')
uid('LW_SOURCES',  'CE281B2A2E5ACD670023BBC4')
uid('LW_FRAMEWORKS','CE281B2B2E5ACD670023BBC4')
uid('LW_RESOURCES','CE281B2C2E5ACD670023BBC4')
uid('LW_DEBUG',    'CE281B2D2E5ACD670023BBC4')
uid('LW_RELEASE',  'CE281B2E2E5ACD670023BBC4')
uid('LW_CONF_LIST','CE281B2F2E5ACD670023BBC4')
uid('LW_AKIT_REF', 'CE281B302E5ACD670023BBC4')
uid('LW_AKIT_BF',  'CE281B312E5ACD670023BBC4')
uid('LW_LA_BF',    'CE281B322E5ACD670023BBC4')
uid('LW_WB_BF',    'CE281B332E5ACD670023BBC4')
uid('LW_DEP',      'CE281B342E5ACD670023BBC4')
uid('LW_PROXY',    'CE281B352E5ACD670023BBC4')
uid('LW_EMBED_BF', 'CE281B362E5ACD670023BBC4')
uid('LW_WB_REF',   'CE281B372E5ACD670023BBC4')
uid('LW_LA_REF',   'CE281B382E5ACD670023BBC4')
uid('LW_ROOT',     'CE281B392E5ACD670023BBC4')
uid('LW_EXC',      'CE281B3A2E5ACD670023BBC4')

T = uid  # shorthand

with open(PBXPROJ, 'r', encoding='utf-8') as f:
    content = f.read()

def section_text(name):
    m = re.search(r'/\* Begin %s section \*/(.*?)/\* End %s section \*/' % (name, name), content, re.DOTALL)
    return m.group(0) if m else ''

def replace_section(name, new_content):
    global content
    old = section_text(name)
    if old:
        content = content.replace(old, new_content)

def insert_before_end(name, new_entries):
    old = section_text(name)
    if not old:
        return
    idx = old.rfind('\n')
    if idx < 0:
        return
    new = old[:idx] + '\n' + new_entries + old[idx:]
    replace_section(name, new)

# ---- Build file entries ----
bf = (
    '\t\t' + T('LW_AKIT_BF') + ' /* ActivityKit.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = ' + T('LW_AKIT_REF') + ' /* ActivityKit.framework */; };\n'
    '\t\t' + T('LW_LA_BF') + ' /* LiveActivityAttributes.swift in Sources */ = {isa = PBXBuildFile; fileRef = ' + T('LW_LA_REF') + ' /* LiveActivityAttributes.swift */; };\n'
    '\t\t' + T('LW_WB_BF') + ' /* LiveActivityWidgetBundle.swift in Sources */ = {isa = PBXBuildFile; fileRef = ' + T('LW_WB_REF') + ' /* LiveActivityWidgetBundle.swift */; };\n'
    '\t\t' + T('LW_EMBED_BF') + ' /* liveAPPWidget.appex in Embed Foundation Extensions */ = {isa = PBXBuildFile; fileRef = ' + T('LW_PRODUCT') + ' /* liveAPPWidget.appex */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };\n'
)
insert_before_end('PBXBuildFile', bf)

# ---- ContainerItemProxy ----
proxy = (
    '\t\t' + T('LW_PROXY') + ' /* PBXContainerItemProxy */ = {\n'
    '\t\t\tisa = PBXContainerItemProxy;\n'
    '\t\t\tcontainerPortal = CE28199A2E5AB3750023BBC4 /* Project object */;\n'
    '\t\t\tproxyType = 1;\n'
    '\t\t\tremoteGlobalIDString = ' + T('LW_TARGET') + ';\n'
    '\t\t\tremoteInfo = liveAPPWidget;\n'
    '\t\t};\n'
)
insert_before_end('PBXContainerItemProxy', proxy)

# ---- FileReference ----
fr = (
    '\t\t' + T('LW_LA_REF') + ' /* LiveActivityAttributes.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = LiveActivityAttributes.swift; path = liveAPP/LiveActivityAttributes.swift; sourceTree = SOURCE_ROOT; };\n'
    '\t\t' + T('LW_AKIT_REF') + ' /* ActivityKit.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = ActivityKit.framework; path = System/Library/Frameworks/ActivityKit.framework; sourceTree = SDKROOT; };\n'
    '\t\t' + T('LW_PRODUCT') + ' /* liveAPPWidget.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = liveAPPWidget.appex; sourceTree = BUILT_PRODUCTS_DIR; };\n'
    '\t\t' + T('LW_WB_REF') + ' /* LiveActivityWidgetBundle.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LiveActivityWidgetBundle.swift; sourceTree = "<group>"; };\n'
)
insert_before_end('PBXFileReference', fr)

# ---- FileSystemSynchronizedRootGroup ----
root_grp = (
    '\t\t' + T('LW_ROOT') + ' /* liveAPPWidget */ = {\n'
    '\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n'
    '\t\t\tpath = liveAPPWidget;\n'
    '\t\t\tsourceTree = "<group>";\n'
    '\t\t};\n'
)
insert_before_end('PBXFileSystemSynchronizedRootGroup', root_grp)

# ---- FileSystemSynchronizedBuildFileExceptionSet ----
exc = (
    '\t\t' + T('LW_EXC') + ' /* liveAPPWidget */ = {\n'
    '\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n'
    '\t\t\tmembership = {\n'
    '\t\t\t\t' + T('LW_TARGET') + '; /* liveAPPWidget */\n'
    '\t\t\t};\n'
    '\t\t\ttargetedMembership = {\n'
    '\t\t\t};\n'
    '\t\t\tglobalExcptions = (\n'
    '\t\t\t\tInfo.plist\n'
    '\t\t\t);\n'
    '\t\t};\n'
)
insert_before_end('PBXFileSystemSynchronizedBuildFileExceptionSet', exc)

# ---- FrameworksBuildPhase ----
fw = (
    '\t\t' + T('LW_FRAMEWORKS') + ' /* Frameworks */ = {\n'
    '\t\t\tisa = PBXFrameworksBuildPhase;\n'
    '\t\t\tbuildActionMask = 2147483647;\n'
    '\t\t\tfiles = (\n'
    '\t\t\t\t' + T('LW_AKIT_BF') + ' /* ActivityKit.framework in Frameworks */,\n'
    '\t\t\t);\n'
    '\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
    '\t\t};\n'
)
insert_before_end('PBXFrameworksBuildPhase', fw)

# ---- PBXGroup ----
old_grp = section_text('PBXGroup')

# Root group children
rg = re.search(r'(CE281999 = \{.*?children = \()([^)]*?)(\).*?\};)', old_grp, re.DOTALL)
if rg:
    new_mid = rg.group(2).rstrip(',\n\t ') + ',\n\t\t\t\t' + T('LW_ROOT') + ' /* liveAPPWidget */,\n\t\t\t'
    old_grp = old_grp.replace(rg.group(0), rg.group(1) + new_mid + rg.group(3))

# Frameworks group children
fg = re.search(r'(CE2819D5[0-9A-F]* = \{.*?children = \()([^)]*?)(\).*?\};)', old_grp, re.DOTALL)
if fg:
    new_mid = fg.group(2).rstrip(',\n\t ') + ',\n\t\t\t\t' + T('LW_AKIT_REF') + ' /* ActivityKit.framework */,\n\t\t\t'
    old_grp = old_grp.replace(fg.group(0), fg.group(1) + new_mid + fg.group(3))

# Products group children
pg = re.search(r'(CE2819A3[0-9A-F]* = \{.*?children = \()([^)]*?)(\).*?\};)', old_grp, re.DOTALL)
if pg:
    new_mid = pg.group(2).rstrip(',\n\t ') + ',\n\t\t\t\t' + T('LW_PRODUCT') + ' /* liveAPPWidget.appex */,\n\t\t\t'
    old_grp = old_grp.replace(pg.group(0), pg.group(1) + new_mid + pg.group(3))

replace_section('PBXGroup', old_grp)

# ---- PBXNativeTarget ----
native = (
    '\t\t' + T('LW_TARGET') + ' /* liveAPPWidget */ = {\n'
    '\t\t\tisa = PBXNativeTarget;\n'
    '\t\t\tbuildConfigurationList = ' + T('LW_CONF_LIST') + ' /* Build configuration list for PBXNativeTarget \\"liveAPPWidget\\" */;\n'
    '\t\t\tbuildPhases = (\n'
    '\t\t\t\t' + T('LW_SOURCES') + ' /* Sources */,\n'
    '\t\t\t\t' + T('LW_FRAMEWORKS') + ' /* Frameworks */,\n'
    '\t\t\t\t' + T('LW_RESOURCES') + ' /* Resources */,\n'
    '\t\t\t);\n'
    '\t\t\tbuildRules = (\n'
    '\t\t\t);\n'
    '\t\t\tdependencies = (\n'
    '\t\t\t);\n'
    '\t\t\tname = liveAPPWidget;\n'
    '\t\t\tpackageProductDependencies = (\n'
    '\t\t\t);\n'
    '\t\t\tproductName = liveAPPWidget;\n'
    '\t\t\tproductReference = ' + T('LW_PRODUCT') + ';\n'
    '\t\t\tproductType = "com.apple.product-type.app-extension";\n'
    '\t\t};\n'
)
insert_before_end('PBXNativeTarget', native)

# ---- PBXProject - add target ----
old_proj = section_text('PBXProject')
pm = re.search(r'(targets = \()([^)]*?)(\);)', old_proj, re.DOTALL)
if pm:
    new_mid = pm.group(2).rstrip(',\n\t ') + ',\n\t\t\t\t' + T('LW_TARGET') + ' /* liveAPPWidget */,\n\t\t\t'
    old_proj = old_proj.replace(pm.group(0), pm.group(1) + new_mid + pm.group(3))
replace_section('PBXProject', old_proj)

# ---- PBXSourcesBuildPhase ----
src = (
    '\t\t' + T('LW_SOURCES') + ' /* Sources */ = {\n'
    '\t\t\tisa = PBXSourcesBuildPhase;\n'
    '\t\t\tbuildActionMask = 2147483647;\n'
    '\t\t\tfiles = (\n'
    '\t\t\t\t' + T('LW_WB_BF') + ' /* LiveActivityWidgetBundle.swift in Sources */,\n'
    '\t\t\t\t' + T('LW_LA_BF') + ' /* LiveActivityAttributes.swift in Sources */,\n'
    '\t\t\t);\n'
    '\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
    '\t\t};\n'
)
insert_before_end('PBXSourcesBuildPhase', src)

# ---- PBXResourcesBuildPhase ----
res = (
    '\t\t' + T('LW_RESOURCES') + ' /* Resources */ = {\n'
    '\t\t\tisa = PBXResourcesBuildPhase;\n'
    '\t\t\tbuildActionMask = 2147483647;\n'
    '\t\t\tfiles = (\n'
    '\t\t\t);\n'
    '\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
    '\t\t};\n'
)
insert_before_end('PBXResourcesBuildPhase', res)

# ---- PBXTargetDependency ----
dep = (
    '\t\t' + T('LW_DEP') + ' /* PBXTargetDependency */ = {\n'
    '\t\t\tisa = PBXTargetDependency;\n'
    '\t\t\tname = liveAPPWidget;\n'
    '\t\t\ttargetProxy = ' + T('LW_PROXY') + ';\n'
    '\t\t};\n'
)
insert_before_end('PBXTargetDependency', dep)

# ---- XCBuildConfiguration ----
build = (
    '\t\t' + T('LW_DEBUG') + ' /* Debug */ = {\n'
    '\t\t\tisa = XCBuildConfiguration;\n'
    '\t\t\tbuildSettings = {\n'
    '\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
    '\t\t\t\tCURRENT_PROJECT_VERSION = 2026071505;\n'
    '\t\t\t\tDEVELOPMENT_TEAM = DD4ZZ69XV7;\n'
    '\t\t\t\tINFOPLIST_FILE = liveAPPWidget/Info.plist;\n'
    '\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "ReplyKit 即時動態";\n'
    '\t\t\t\tINFOPLIST_KEY_NSSupportsLiveActivities = YES;\n'
    '\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.6;\n'
    '\t\t\t\tMARKETING_VERSION = 13.2.9;\n'
    '\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = nuclear.liveAPP.liveAPPWidget;\n'
    '\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";\n'
    '\t\t\t\tSKIP_INSTALL = YES;\n'
    '\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n'
    '\t\t\t\tSWIFT_VERSION = 5.0;\n'
    '\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n'
    '\t\t\t};\n'
    '\t\t\tname = Debug;\n'
    '\t\t};\n'
    '\t\t' + T('LW_RELEASE') + ' /* Release */ = {\n'
    '\t\t\tisa = XCBuildConfiguration;\n'
    '\t\t\tbuildSettings = {\n'
    '\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
    '\t\t\t\tCURRENT_PROJECT_VERSION = 2026071505;\n'
    '\t\t\t\tDEVELOPMENT_TEAM = DD4ZZ69XV7;\n'
    '\t\t\t\tINFOPLIST_FILE = liveAPPWidget/Info.plist;\n'
    '\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "ReplyKit 即時動態";\n'
    '\t\t\t\tINFOPLIST_KEY_NSSupportsLiveActivities = YES;\n'
    '\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.6;\n'
    '\t\t\t\tMARKETING_VERSION = 13.2.9;\n'
    '\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = nuclear.liveAPP.liveAPPWidget;\n'
    '\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";\n'
    '\t\t\t\tSKIP_INSTALL = YES;\n'
    '\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n'
    '\t\t\t\tSWIFT_VERSION = 5.0;\n'
    '\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n'
    '\t\t\t};\n'
    '\t\t\tname = Release;\n'
    '\t\t};\n'
)
insert_before_end('XCBuildConfiguration', build)

# ---- XCConfigurationList ----
cl = (
    '\t\t' + T('LW_CONF_LIST') + ' /* Build configuration list for PBXNativeTarget \\"liveAPPWidget\\" */ = {\n'
    '\t\t\tisa = XCConfigurationList;\n'
    '\t\t\tbuildConfigurations = (\n'
    '\t\t\t\t' + T('LW_DEBUG') + ' /* Debug */,\n'
    '\t\t\t\t' + T('LW_RELEASE') + ' /* Release */,\n'
    '\t\t\t);\n'
    '\t\t\tdefaultConfigurationIsVisible = 0;\n'
    '\t\t\tdefaultConfigurationName = Release;\n'
    '\t\t};\n'
)
insert_before_end('XCConfigurationList', cl)

# ---- Embed Foundation Extensions ----
old_embed = section_text('PBXCopyFilesBuildPhase')
em = re.search(r'(CE281A08[0-9A-F]* = \{.*?files = \()([^)]*?)(\).*?\};)', old_embed, re.DOTALL)
if em:
    new_mid = em.group(2).rstrip(',\n\t ') + ',\n\t\t\t\t' + T('LW_EMBED_BF') + ' /* liveAPPWidget.appex in Embed Foundation Extensions */,\n\t\t\t'
    old_embed = old_embed.replace(em.group(0), em.group(1) + new_mid + em.group(3))
    replace_section('PBXCopyFilesBuildPhase', old_embed)

# ---- TargetAttributes ----
old_proj2 = section_text('PBXProject')
tam = re.search(r'(TargetAttributes = \{)([^}]*?)(\};)', old_proj2, re.DOTALL)
if tam:
    new_mid = ('\n\t\t\t\t' + T('LW_TARGET') + ' = {\n'
               '\t\t\t\t\tCreatedOnToolsVersion = 16.3;\n'
               '\t\t\t\t};\n\t\t\t\t'
               + tam.group(2).strip())
    old_proj2 = old_proj2.replace(tam.group(0), tam.group(1) + new_mid + '\n\t\t\t' + tam.group(3))
    replace_section('PBXProject', old_proj2)

# Write
with open(PBXPROJ, 'w', encoding='utf-8') as f:
    f.write(content)

print('pbxproj updated')

# Verify
with open(PBXPROJ, 'r', encoding='utf-8') as f:
    final = f.read()

ok = True
for k, v in U.items():
    if v not in final:
        print('MISSING: ' + k + ' = ' + v)
        ok = False
if ok:
    print('ALL UUIDs present')
