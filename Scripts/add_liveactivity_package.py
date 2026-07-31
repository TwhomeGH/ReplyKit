#!/usr/bin/env python3
"""Add LiveActivityKit local Swift package to liveAPP.xcodeproj/project.pbxproj"""

import re

PBXPROJ = 'liveAPP.xcodeproj/project.pbxproj'

PACKAGE_REF = 'CE281C102E5ACD670023BBC4'
PRODUCT_DEP = 'CE281C112E5ACD670023BBC4'

with open(PBXPROJ, 'r', encoding='utf-8') as f:
    content = f.read()

# === 1. XCLocalSwiftPackageReference section ===
# The section doesn't exist yet - insert before PBXProject section
if 'XCLocalSwiftPackageReference section' not in content:
    local_ref = (
        '/* Begin XCLocalSwiftPackageReference section */\n'
        '\t\t' + PACKAGE_REF + ' /* XCLocalSwiftPackageReference "LiveActivityKit" */ = {\n'
        '\t\t\tisa = XCLocalSwiftPackageReference;\n'
        '\t\t\trelativePath = LiveActivityKit;\n'
        '\t\t};\n'
        '/* End XCLocalSwiftPackageReference section */\n'
    )
    content = content.replace('/* Begin PBXProject section */', local_ref + '\n/* Begin PBXProject section */')

# === 2. XCSwiftPackageProductDependency ===
# Insert before the End marker of that section
prod_dep = (
    '\t\t' + PRODUCT_DEP + ' /* LiveActivityKit */ = {\n'
    '\t\t\tisa = XCSwiftPackageProductDependency;\n'
    '\t\t\tpackage = ' + PACKAGE_REF + ' /* XCLocalSwiftPackageReference "LiveActivityKit" */;\n'
    '\t\t\tproductName = LiveActivityKit;\n'
    '\t\t};\n'
)
if 'XCSwiftPackageProductDependency section' in content:
    idx = content.find('/* End XCSwiftPackageProductDependency section */')
    content = content[:idx] + prod_dep + content[idx:]
else:
    # Section doesn't exist - create it before XCConfigurationList
    sec = (
        '/* Begin XCSwiftPackageProductDependency section */\n'
        + prod_dep
        + '/* End XCSwiftPackageProductDependency section */\n'
    )
    content = content.replace('/* Begin XCConfigurationList section */', sec + '\n/* Begin XCConfigurationList section */')

# === 3. Add product dependency to main app target ===
main_pkg_deps = re.search(
    r'(CE2819A12E5AB3750023BBC4 /\* liveAPP \*/ = \{.*?packageProductDependencies = \()([^)]*?)(\);)', content, re.DOTALL
)
if main_pkg_deps:
    new_mid = main_pkg_deps.group(2).rstrip(',\n\t ') + ',\n\t\t\t\t' + PRODUCT_DEP + ' /* LiveActivityKit */,\n\t\t\t'
    content = content.replace(main_pkg_deps.group(0), main_pkg_deps.group(1) + new_mid + main_pkg_deps.group(3))

# === 4. Add product dependency to widget target ===
widget_pkg_deps = re.search(
    r'(CE281B282E5ACD670023BBC4 /\* liveAPPWidget \*/ = \{.*?packageProductDependencies = \()([^)]*?)(\);)', content, re.DOTALL
)
if widget_pkg_deps:
    new_mid = widget_pkg_deps.group(2).rstrip(',\n\t ') + ',\n\t\t\t\t' + PRODUCT_DEP + ' /* LiveActivityKit */,\n\t\t\t'
    content = content.replace(widget_pkg_deps.group(0), widget_pkg_deps.group(1) + new_mid + widget_pkg_deps.group(3))

# === 5. Add package reference to PBXProject.packageReferences ===
pkg_refs = re.search(
    r'(packageReferences = \()([^)]*?)(\);)', content, re.DOTALL
)
if pkg_refs:
    new_mid = pkg_refs.group(2).rstrip(',\n\t ') + ',\n\t\t\t\t' + PACKAGE_REF + ' /* XCLocalSwiftPackageReference "LiveActivityKit" */,\n\t\t\t'
    content = content.replace(pkg_refs.group(0), pkg_refs.group(1) + new_mid + pkg_refs.group(3))

# === 6. Remove LiveActivityAttributes.swift from widget Sources phase ===
old_sources = '''\t\tCE281B2A2E5ACD670023BBC4 /* Sources */ = {
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\tCE281B322E5ACD670023BBC4 /* LiveActivityAttributes.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};'''
new_sources = '''\t\tCE281B2A2E5ACD670023BBC4 /* Sources */ = {
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};'''
if old_sources in content:
    content = content.replace(old_sources, new_sources)
else:
    print('WARN: widget Sources phase pattern not found - check manually')

# === 7. Remove PBXBuildFile entry for LiveActivityAttributes ===
content = content.replace('\t\tCE281B322E5ACD670023BBC4 /* LiveActivityAttributes.swift in Sources */ = {isa = PBXBuildFile; fileRef = CE281B382E5ACD670023BBC4 /* LiveActivityAttributes.swift */; };\n', '')

# === 8. Remove PBXFileReference entry for LiveActivityAttributes ===
content = content.replace('\t\tCE281B382E5ACD670023BBC4 /* LiveActivityAttributes.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = LiveActivityAttributes.swift; path = liveAPP/LiveActivityAttributes.swift; sourceTree = SOURCE_ROOT; };\n', '')

with open(PBXPROJ, 'w', encoding='utf-8') as f:
    f.write(content)

print('pbxproj updated')

# Verify
final = open(PBXPROJ, encoding='utf-8').read()
print('Package ref present:', PACKAGE_REF in final)
print('Product dep present:', PRODUCT_DEP in final)
print('Widget Sources empty of LA:', 'LiveActivityAttributes.swift in Sources' not in final)
print('LA build file removed:', 'CE281B322E5ACD670023BBC4' not in final)
print('LA file ref removed:', 'CE281B382E5ACD670023BBC4' not in final)
print('Main app has product dep:', PRODUCT_DEP + ' /* LiveActivityKit */' in final)
print('Widget has product dep:', PRODUCT_DEP in final)
