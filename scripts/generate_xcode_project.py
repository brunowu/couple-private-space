#!/usr/bin/env python3
"""Generate the small native host project; domain implementation stays in SwiftPM."""
from pathlib import Path
import hashlib
root=Path(__file__).resolve().parent.parent
project=root/'Apps/iOS/CouplePrivateSpace.xcodeproj'
project.mkdir(parents=True,exist_ok=True)
ids={name:hashlib.sha256(name.encode()).hexdigest()[:24].upper() for name in ['project','main','products','appFile','testFile','assetsFile','appProduct','testProduct','appTarget','testTarget','appSources','testSources','appFrameworks','testFrameworks','appResources','appBuild','testBuild','assetsBuild','uiProduct','labProduct','runtimeProduct','runtimeBuild','uiBuild','labBuild','package','projectConfig','appConfig','testConfig','pDebug','pRelease','aDebug','aRelease','tDebug','tRelease','proxy','dependency']}
def I(name): return ids[name]
objects=[]
def obj(name,body): objects.append(f'{I(name)} = {{ {body} }};')
obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2660; }}; buildConfigurationList = {I("projectConfig")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; knownRegions = ("zh-Hans", en, Base); mainGroup = {I("main")}; productRefGroup = {I("products")}; projectDirPath = ""; projectRoot = ""; packageReferences = ({I("package")}); targets = ({I("appTarget")}, {I("testTarget")});')
obj('main',f'isa = PBXGroup; children = ({I("appFile")}, {I("testFile")}, {I("assetsFile")}, {I("products")}); sourceTree = "<group>";')
obj('products',f'isa = PBXGroup; name = Products; children = ({I("appProduct")}, {I("testProduct")}); sourceTree = "<group>";')
for name,path in [('appFile','CouplePrivateSpaceApp.swift'),('testFile','UITests/SpaceSmokeTests.swift')]: obj(name,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = "<group>";')
obj('assetsFile','isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
for name,path,kind in [('appProduct','CouplePrivateSpace.app','wrapper.application'),('testProduct','SpaceSmokeTests.xctest','wrapper.cfbundle')]: obj(name,f'isa = PBXFileReference; explicitFileType = {kind}; path = {path}; sourceTree = BUILT_PRODUCTS_DIR;')
obj('package','isa = XCLocalSwiftPackageReference; relativePath = "../..";')
for name,product in [('uiProduct','CoupleUI'),('labProduct','DevelopmentSupport'),('runtimeProduct','CoupleApplication')]: obj(name,f'isa = XCSwiftPackageProductDependency; package = {I("package")}; productName = {product};')
for name,ref in [('appBuild','appFile'),('testBuild','testFile')]: obj(name,f'isa = PBXBuildFile; fileRef = {I(ref)};')
obj('assetsBuild',f'isa = PBXBuildFile; fileRef = {I("assetsFile")};')
for name,ref in [('uiBuild','uiProduct'),('labBuild','labProduct'),('runtimeBuild','runtimeProduct')]: obj(name,f'isa = PBXBuildFile; productRef = {I(ref)};')
for name,kind,files in [('appSources','PBXSourcesBuildPhase',['appBuild']),('testSources','PBXSourcesBuildPhase',['testBuild']),('appFrameworks','PBXFrameworksBuildPhase',['uiBuild','labBuild','runtimeBuild']),('testFrameworks','PBXFrameworksBuildPhase',[]),('appResources','PBXResourcesBuildPhase',['assetsBuild'])]: obj(name,f'isa = {kind}; buildActionMask = 2147483647; files = ({",".join(I(x) for x in files)}); runOnlyForDeploymentPostprocessing = 0;')
obj('appTarget',f'isa = PBXNativeTarget; buildConfigurationList = {I("appConfig")}; buildPhases = ({I("appSources")},{I("appFrameworks")},{I("appResources")}); buildRules = (); dependencies = (); name = CouplePrivateSpace; packageProductDependencies = ({I("uiProduct")},{I("labProduct")},{I("runtimeProduct")}); productName = CouplePrivateSpace; productReference = {I("appProduct")}; productType = "com.apple.product-type.application";')
obj('testTarget',f'isa = PBXNativeTarget; buildConfigurationList = {I("testConfig")}; buildPhases = ({I("testSources")},{I("testFrameworks")}); buildRules = (); dependencies = ({I("dependency")}); name = SpaceSmokeTests; productName = SpaceSmokeTests; productReference = {I("testProduct")}; productType = "com.apple.product-type.bundle.ui-testing";')
obj('proxy',f'isa = PBXContainerItemProxy; containerPortal = {I("project")}; proxyType = 1; remoteGlobalIDString = {I("appTarget")}; remoteInfo = CouplePrivateSpace;')
obj('dependency',f'isa = PBXTargetDependency; target = {I("appTarget")}; targetProxy = {I("proxy")};')
for level,letters in [('project','p'),('app','a'),('test','t')]:
 obj(level+'Config',f'isa = XCConfigurationList; buildConfigurations = ({I(letters+"Debug")},{I(letters+"Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
 for mode in ['Debug','Release']:
  settings={'IPHONEOS_DEPLOYMENT_TARGET':'18.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','SWIFT_ENABLE_EXPLICIT_MODULES':'NO'}
  if mode=='Debug': settings.update({'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG','SWIFT_OPTIMIZATION_LEVEL':'-Onone','GCC_PREPROCESSOR_DEFINITIONS':'DEBUG=1','ONLY_ACTIVE_ARCH':'YES'})
  if level!='project': settings.update({'GENERATE_INFOPLIST_FILE':'YES','TARGETED_DEVICE_FAMILY':'1','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'7UBMFSCK2T','PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':'private.couple.space.development' + ('.uitests' if level=='test' else '')})
  if level=='app': settings.update({'INFOPLIST_KEY_CFBundleDisplayName':'我们','MARKETING_VERSION':'0.9.3','CURRENT_PROJECT_VERSION':'7','INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon'})
  if level=='app': settings.update({'CODE_SIGN_ENTITLEMENTS':'CouplePrivateSpace.entitlements','APS_ENVIRONMENT':'development' if mode=='Debug' else 'production','PUSH_ENVIRONMENT':'sandbox' if mode=='Debug' else 'production','INFOPLIST_FILE':'PushInfo.plist'})
  if level=='test': settings['TEST_TARGET_NAME']='CouplePrivateSpace'
  encoded=' '.join(f'{k} = "{v}";' for k,v in settings.items())
  obj(letters+mode,f'isa = XCBuildConfiguration; buildSettings = {{ {encoded} }}; name = {mode};')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {I("project")}; }}\n')
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
def ref(target,name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{I(target)}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:CouplePrivateSpace.xcodeproj"/>'
(schemes/'CouplePrivateSpace.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('appTarget','CouplePrivateSpace.app')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('testTarget','SpaceSmokeTests.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('appTarget','CouplePrivateSpace.app')}</BuildableProductRunnable></LaunchAction></Scheme>''')
print(project)
