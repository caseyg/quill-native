#!/usr/bin/env python3
"""Generate the dependency-free checked-in Xcode project using Python's standard library."""
from pathlib import Path
import hashlib
ROOT=Path(__file__).resolve().parents[1]
objects={}
def ident(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def add(key,isa,**kwargs):
    i=ident(key); objects[i]={'isa':isa,**kwargs}; return i
def configlist(key,settings):
    cs=[]
    for name in ('Debug','Release'):
        s=dict(settings)
        s.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf','ONLY_ACTIVE_ARCH':'YES' if name=='Debug' else 'NO','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if name=='Debug' else ''})
        configuration={'name':name,'buildSettings':s}
        if key=='project': configuration['baseConfigurationReference']=ident('signingconfig')
        cs.append(add(key+name,'XCBuildConfiguration',**configuration))
    return add(key+'list','XCConfigurationList',buildConfigurations=cs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
projectsettings={'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','ENABLE_USER_SCRIPT_SANDBOXING':'YES','CODE_SIGN_STYLE':'Automatic','REGISTER_APP_GROUPS':'YES','TARGETED_DEVICE_FAMILY':'1,2'}
signingref=add('signingconfig','PBXFileReference',lastKnownFileType='text.xcconfig',path='Config/Signing.xcconfig',sourceTree='SOURCE_ROOT')
projconfig=configlist('project',projectsettings)
products=[]; filerefs=[signingref]; targetids={}; phases={}
package=add('corepackage','XCLocalSwiftPackageReference',relativePath='QuillCore')
for name in ('QuillNative','QuillShare','QuillNativeUITests'):
    ext='app' if name=='QuillNative' else ('appex' if name=='QuillShare' else 'xctest')
    product=add(name+'product','PBXFileReference',explicitFileType='wrapper.application' if ext=='app' else ('wrapper.app-extension' if ext=='appex' else 'wrapper.cfbundle'),includeInIndex=0,path=name+'.'+ext,sourceTree='BUILT_PRODUCTS_DIR')
    products.append(product)
    if name=='QuillNative': files=sorted(ROOT.glob('QuillNative/**/*.swift'))
    elif name=='QuillShare': files=sorted(ROOT.glob('ShareExtension/*.swift'))+[ROOT/'QuillNative/Services'/n for n in ('SharedStorage.swift','Keychain.swift','LinkContext.swift')]+[ROOT/'QuillNative/Support'/n for n in ('Compat.swift','Theme.swift')]
    else: files=sorted(ROOT.glob('QuillNativeUITests/*.swift'))
    builds=[]
    for f in files:
        path=str(f.relative_to(ROOT)); ref=add(path,'PBXFileReference',lastKnownFileType='sourcecode.swift',path=path,sourceTree='<group>')
        if ref not in filerefs: filerefs.append(ref)
        builds.append(add(name+path+'build','PBXBuildFile',fileRef=ref))
    sources=add(name+'sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=builds,runOnlyForDeploymentPostprocessing=0)
    frameworkfiles=[]; deps=[]
    if name!='QuillNativeUITests':
        dep=add(name+'core','XCSwiftPackageProductDependency',package=package,productName='QuillCore'); deps=[dep]
        frameworkfiles=[add(name+'corebuild','PBXBuildFile',productRef=dep)]
    frameworks=add(name+'frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=frameworkfiles,runOnlyForDeploymentPostprocessing=0)
    resourcefiles=[]
    if name=='QuillNative':
        asset=add('assets','PBXFileReference',lastKnownFileType='folder.assetcatalog',path='QuillNative/Assets.xcassets',sourceTree='<group>'); filerefs.append(asset)
        resourcefiles=[add('assetsbuild','PBXBuildFile',fileRef=asset)]
    resources=add(name+'resources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=resourcefiles,runOnlyForDeploymentPostprocessing=0)
    settings={'PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':{'QuillNative':'com.quillnative.app','QuillShare':'com.quillnative.app.share','QuillNativeUITests':'com.quillnative.app.uitests'}[name],'GENERATE_INFOPLIST_FILE':'NO','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks','MARKETING_VERSION':'1.0','CURRENT_PROJECT_VERSION':'1'}
    if name=='QuillNativeUITests': settings.update({'GENERATE_INFOPLIST_FILE':'YES','TEST_TARGET_NAME':'QuillNative'})
    else: settings.update({'INFOPLIST_FILE':'Config/App-Info.plist' if name=='QuillNative' else 'Config/Share-Info.plist','CODE_SIGN_ENTITLEMENTS':'Config/App.entitlements' if name=='QuillNative' else 'Config/Share.entitlements'})
    if name=='QuillNative': settings.update({'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon'})
    if name=='QuillShare': settings.update({'APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'})
    targetids[name]=add(name+'target','PBXNativeTarget',buildConfigurationList=configlist(name,settings),buildPhases=[sources,frameworks,resources],buildRules=[],dependencies=[],name=name,packageProductDependencies=deps,productName=name,productReference=product,productType={'QuillNative':'com.apple.product-type.application','QuillShare':'com.apple.product-type.app-extension','QuillNativeUITests':'com.apple.product-type.bundle.ui-testing'}[name])
proxy=add('shareproxy','PBXContainerItemProxy',containerPortal=ident('project'),proxyType=1,remoteGlobalIDString=targetids['QuillShare'],remoteInfo='QuillShare')
dep=add('sharedep','PBXTargetDependency',target=targetids['QuillShare'],targetProxy=proxy)
objects[targetids['QuillNative']]['dependencies']=[dep]
embedfile=add('embedshare','PBXBuildFile',fileRef=ident('QuillShareproduct'),settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
embed=add('embedphase','PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=[embedfile],name='Embed App Extensions',runOnlyForDeploymentPostprocessing=0)
objects[targetids['QuillNative']]['buildPhases'].append(embed)
proxy=add('appproxy','PBXContainerItemProxy',containerPortal=ident('project'),proxyType=1,remoteGlobalIDString=targetids['QuillNative'],remoteInfo='QuillNative')
objects[targetids['QuillNativeUITests']]['dependencies']=[add('appdep','PBXTargetDependency',target=targetids['QuillNative'],targetProxy=proxy)]
productgroup=add('products','PBXGroup',children=products,name='Products',sourceTree='<group>')
main=add('main','PBXGroup',children=filerefs+[productgroup],sourceTree='<group>')
targetattributes={targetids['QuillNativeUITests']:{'TestTargetID':targetids['QuillNative']}}
for appname in ('QuillNative','QuillShare'):
    targetattributes[targetids[appname]]={'SystemCapabilities':{'com.apple.ApplicationGroups.iOS':{'enabled':1}}}
project=add('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2600','TargetAttributes':targetattributes},buildConfigurationList=projconfig,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=main,productRefGroup=productgroup,projectDirPath='',projectRoot='',targets=list(targetids.values()),packageReferences=[package])
def serialize(v,indent=0):
    if isinstance(v,dict): return '{\n'+''.join('\t'*(indent+1)+quote(k)+' = '+serialize(val,indent+1)+';\n' for k,val in v.items())+'\t'*indent+'}'
    if isinstance(v,list): return '('+', '.join(serialize(x,indent) for x in v)+')'
    if isinstance(v,int): return str(v)
    if v in objects: return v
    return quote(v)
def quote(v): return '"'+str(v).replace('\\','\\\\').replace('"','\\"')+'"'
projectdir=ROOT/'QuillNative.xcodeproj'; projectdir.mkdir(exist_ok=True)
(projectdir/'project.pbxproj').write_text('// !$*UTF8*$!\n'+serialize({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project})+'\n')
schemedir=projectdir/'xcshareddata/xcschemes'; schemedir.mkdir(parents=True,exist_ok=True)
def ref(name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{targetids[name]}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:QuillNative.xcodeproj"/>'
(schemedir/'QuillNative.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('QuillNative')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('QuillNativeUITests').replace('.app','.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('QuillNative')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('QuillNative')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(projectdir)
