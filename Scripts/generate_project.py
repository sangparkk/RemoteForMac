#!/usr/bin/env python3
"""Standard-library-only, deterministic Xcode project generation. Output is checked in."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent
objects = {}

def ident(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(str(value), ensure_ascii=False)

def add(key, content):
    result = ident(key)
    objects[result] = content
    return result

def array(values):
    return '(' + ', '.join(values) + ')'

def configs(key, settings):
    ids = []
    for mode in ['Debug', 'Release']:
        values = dict(settings)
        values['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if mode == 'Debug' else '-O'
        values['DEBUG_INFORMATION_FORMAT'] = 'dwarf' if mode == 'Debug' else 'dwarf-with-dsym'
        if mode == 'Debug': values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        fields = ' '.join(f'{k} = {quote(v)};' for k, v in values.items())
        ids.append(add(key + mode, f'isa = XCBuildConfiguration; buildSettings = {{ {fields} }}; name = {mode};'))
    return add(key + 'configs', f'isa = XCConfigurationList; buildConfigurations = {array(ids)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

refs = {}
for file in sorted([*ROOT.glob('Shared/*.swift'), *ROOT.glob('MacHost/*.swift'), *ROOT.glob('iPhoneRemote/*.swift')]):
    path = file.relative_to(ROOT).as_posix()
    refs[path] = add(path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(path)}; sourceTree = SOURCE_ROOT;')

products, targets = [], []
for name, folder, sdk, extra in [
    ('RemoteTVHost', 'MacHost', 'macosx', {'MACOSX_DEPLOYMENT_TARGET':'14.0','INFOPLIST_FILE':'Resources/Host-Info.plist','ENABLE_APP_SANDBOX':'NO','ENABLE_HARDENED_RUNTIME':'YES','CODE_SIGN_ENTITLEMENTS':'Resources/Host.entitlements'}),
    ('RemoteTVPhone', 'iPhoneRemote', 'iphoneos', {'IPHONEOS_DEPLOYMENT_TARGET':'17.0','INFOPLIST_FILE':'Resources/Phone-Info.plist','TARGETED_DEVICE_FAMILY':'1','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO'})
]:
    display_name = 'RemoteForMac Host' if folder == 'MacHost' else 'RemoteForMac'
    product = add(name + 'product', f'isa = PBXFileReference; explicitFileType = wrapper.application; path = {quote(display_name + ".app")}; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product)
    builds = []
    for path, ref in refs.items():
        if path.startswith(('Shared/', folder + '/')):
            builds.append(add(name + path, f'isa = PBXBuildFile; fileRef = {ref};'))
    sources = add(name + 'sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(builds)}; runOnlyForDeploymentPostprocessing = 0;')
    frameworks = add(name + 'frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    asset_path = 'Resources/' + ('Host' if folder == 'MacHost' else 'Phone') + 'Assets.xcassets'
    asset_ref = add(asset_path, f'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {quote(asset_path)}; sourceTree = SOURCE_ROOT;')
    resource_builds = [add(name + asset_path, f'isa = PBXBuildFile; fileRef = {asset_ref};')]
    if folder == 'MacHost':
        web_ref = add('Resources/WebRemote', 'isa = PBXFileReference; lastKnownFileType = folder; path = "Resources/WebRemote"; sourceTree = SOURCE_ROOT;')
        resource_builds.append(add(name + 'Resources/WebRemote', f'isa = PBXBuildFile; fileRef = {web_ref};'))
    resources = add(name + 'resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array(resource_builds)}; runOnlyForDeploymentPostprocessing = 0;')
    configuration = configs(name, {'PRODUCT_NAME':display_name,'EXECUTABLE_NAME':name,'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','PRODUCT_BUNDLE_IDENTIFIER':'personal.remotetv.' + ('host' if folder == 'MacHost' else 'phone'), 'SDKROOT':sdk,'SWIFT_VERSION':'5.0','CODE_SIGN_STYLE':'Automatic','GENERATE_INFOPLIST_FILE':'NO','ENABLE_USER_SCRIPT_SANDBOXING':'YES',**extra})
    target = add(name + 'target', f'isa = PBXNativeTarget; buildConfigurationList = {configuration}; buildPhases = {array([sources, frameworks, resources])}; buildRules = (); dependencies = (); name = {name}; productName = {name}; productReference = {product}; productType = "com.apple.product-type.application";')
    targets.append(target)
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.7">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
 <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{display_name}.app" BlueprintName="{name}" ReferencedContainer="container:RemoteTV.xcodeproj"/></BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{display_name}.app" BlueprintName="{name}" ReferencedContainer="container:RemoteTV.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    (ROOT/'RemoteTV.xcodeproj/xcshareddata/xcschemes'/f'{name}.xcscheme').write_text(scheme)

products_group = add('products', f'isa = PBXGroup; children = {array(products)}; name = Products; sourceTree = "<group>";')
main_group = add('main', f'isa = PBXGroup; children = {array(list(refs.values()) + [products_group])}; sourceTree = "<group>";')
project_configs = configs('project', {'CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'targeted'})
project = add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2630; }}; buildConfigurationList = {project_configs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ko; hasScannedForEncodings = 0; knownRegions = (ko, en, Base); mainGroup = {main_group}; productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; targets = {array(targets)};')
text = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
text += '\n'.join(f'{key} = {{ {value} }};' for key, value in objects.items())
text += f'\n}}; rootObject = {project}; }}\n'
(ROOT/'RemoteTV.xcodeproj/project.pbxproj').write_text(text)
print('Generated RemoteTV.xcodeproj with macOS and iOS targets.')
