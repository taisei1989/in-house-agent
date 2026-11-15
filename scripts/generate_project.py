"""Generate the small native Xcode project without a third-party generator."""
from pathlib import Path
import json

root = Path(__file__).resolve().parents[1]
project = root / "InHouseAgent.xcodeproj"
project.mkdir(exist_ok=True)
project.joinpath("project.pbxproj").write_text('''// !$*UTF8*$!
{
 archiveVersion = 1; classes = {}; objectVersion = 56;
 objects = {
 A001 = {isa = PBXProject; attributes = {LastUpgradeCheck = 2660;}; buildConfigurationList = A002; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, ja, Base); mainGroup = A003; productRefGroup = A004; projectDirPath = ""; projectRoot = ""; targets = (A005);};
 A002 = {isa = XCConfigurationList; buildConfigurations = (A010,A011); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;};
 A003 = {isa = PBXGroup; children = (A006,A007,A004); sourceTree = "<group>";};
 A004 = {isa = PBXGroup; children = (A008); name = Products; sourceTree = "<group>";};
 A005 = {isa = PBXNativeTarget; buildConfigurationList = A009; buildPhases = (A012,A013,A014); buildRules = (); dependencies = (); name = InHouseAgent; productName = InHouseAgent; productReference = A008; productType = "com.apple.product-type.application";};
 A006 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App/InHouseAgentApp.swift; sourceTree = "<group>";};
 A007 = {isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = App/Localizable.xcstrings; sourceTree = "<group>";};
 A008 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "In-House Agent.app"; sourceTree = BUILT_PRODUCTS_DIR;};
 A009 = {isa = XCConfigurationList; buildConfigurations = (A015,A016); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;};
 A010 = {isa = XCBuildConfiguration; buildSettings = {MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; SWIFT_VERSION = 5.0;}; name = Debug;};
 A011 = {isa = XCBuildConfiguration; buildSettings = {MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; SWIFT_VERSION = 5.0;}; name = Release;};
 A012 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A017); runOnlyForDeploymentPostprocessing = 0;};
 A013 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;};
 A014 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (A018); runOnlyForDeploymentPostprocessing = 0;};
 A015 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity"; PRODUCT_BUNDLE_IDENTIFIER = "com.taisei1989.inhouseagent"; PRODUCT_NAME = "In-House Agent"; CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 0.1.0; SWIFT_EMIT_LOC_STRINGS = YES; ENABLE_APP_SANDBOX = NO;}; name = Debug;};
 A016 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity"; PRODUCT_BUNDLE_IDENTIFIER = "com.taisei1989.inhouseagent"; PRODUCT_NAME = "In-House Agent"; CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 0.1.0; SWIFT_EMIT_LOC_STRINGS = YES; ENABLE_APP_SANDBOX = NO;}; name = Release;};
 A017 = {isa = PBXBuildFile; fileRef = A006;};
 A018 = {isa = PBXBuildFile; fileRef = A007;};
 }; rootObject = A001;
}
''')
translations = {
"New Chat":"新規チャット", "Server":"サーバー", "Start Server":"サーバーを起動", "Stop Server":"サーバーを停止", "Restart Server":"サーバーを再起動", "Chat":"チャット", "Routines":"ルーティン", "Stopped":"停止中", "Your local assistant":"ローカルAIアシスタント", "Set up a model to start a conversation.":"モデルをセットアップして会話を始めましょう。", "Message":"メッセージ", "Send":"送信", "No routines":"ルーティンがありません", "Schedule tasks to run on this Mac.":"このMacで定期実行するタスクを設定します。", "Server Status":"サーバーの状態", "Status":"状態", "Model":"モデル", "Not configured":"未設定", "Logs":"ログ", "Server logs will appear here.":"サーバーのログがここに表示されます。", "Server: Stopped":"サーバー：停止中", "Model path":"モデルのパス", "Workspace":"作業ディレクトリ", "Allow cloud models":"クラウドモデルの併用を許可", "Start server when the app opens":"アプリ起動時にサーバーを自動起動", "Updates":"アップデート", "Automatically check for updates":"アップデートを自動確認", "Settings":"設定"
}
catalog_path = root / "App/Localizable.xcstrings"
catalog = json.loads(catalog_path.read_text()) if catalog_path.exists() else {
    "sourceLanguage": "en", "strings": {}, "version": "1.0"
}
# Seed missing translations only. Keep edited translations, extra languages,
# comments, plural variations and newly extracted keys across regeneration.
for key, translation in translations.items():
    entry = catalog.setdefault("strings", {}).setdefault(key, {})
    entry.setdefault("localizations", {}).setdefault("ja", {
        "stringUnit": {"state": "translated", "value": translation}
    })
catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")

# Include implementation sources and bundle the Python package and pinned dependencies.
p = project / "project.pbxproj"
text = p.read_text()
objects = []
source_ids, resource_ids, group_ids = [], [], []
for index, source in enumerate(sorted(root.glob("App/*.swift"))):
    if source.name == "InHouseAgentApp.swift":
        continue
    ref, build = f"B{index:03}A", f"B{index:03}B"
    objects += [f'{ref} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "App/{source.name}"; sourceTree = "<group>";}};', f'{build} = {{isa = PBXBuildFile; fileRef = {ref};}};']
    source_ids.append(build); group_ids.append(ref)
for index, (path, kind) in enumerate([("sidecar", "folder"), ("requirements.lock", "text"), ("App/AppIcon.icns", "image.icns")]):
    ref, build = f"C{index:03}A", f"C{index:03}B"
    objects += [f'{ref} = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = "{path}"; sourceTree = "<group>";}};', f'{build} = {{isa = PBXBuildFile; fileRef = {ref};}};']
    resource_ids.append(build); group_ids.append(ref)
text = text.replace('files = (A017)', 'files = (A017,' + ','.join(source_ids) + ')')
text = text.replace('files = (A018)', 'files = (A018,' + ','.join(resource_ids) + ')')
text = text.replace('children = (A006,A007,A004)', 'children = (A006,A007,A004,' + ','.join(group_ids) + ')')
text = text.replace('targets = (A005);', 'targets = (A005); packageReferences = (D001);')
text = text.replace('productType = "com.apple.product-type.application";', 'productType = "com.apple.product-type.application"; packageProductDependencies = (D002);')
text = text.replace('isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ();', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (D003);')
objects += ['D001 = {isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/sparkle-project/Sparkle"; requirement = {kind = exactVersion; version = 2.10.1;};};', 'D002 = {isa = XCSwiftPackageProductDependency; package = D001; productName = Sparkle;};', 'D003 = {isa = PBXBuildFile; productRef = D002;};']
text = text.replace(' }; rootObject', '\n' + '\n'.join(objects) + '\n }; rootObject')
text = text.replace('GENERATE_INFOPLIST_FILE = YES;', 'GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleIconFile = AppIcon; EXECUTABLE_NAME = InHouseAgent; PRODUCT_MODULE_NAME = InHouseAgent; ALWAYS_SEARCH_USER_PATHS = NO; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";')
p.write_text(text)

# Native macOS UI tests use production UI only. Keep real-model execution in
# a separate scheme so scaffold checks cannot load a second large model.
ui_objects = '''
E001 = {isa = PBXNativeTarget; buildConfigurationList = E002; buildPhases = (E005,E006,E007); buildRules = (); dependencies = (E008); name = InHouseAgentUITests; productName = InHouseAgentUITests; productReference = E010; productType = "com.apple.product-type.bundle.ui-testing";};
E002 = {isa = XCConfigurationList; buildConfigurations = (E003,E004); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;};
E003 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = "com.taisei1989.inhouseagent.uitests"; PRODUCT_NAME = "$(TARGET_NAME)"; TEST_TARGET_NAME = InHouseAgent; SWIFT_VERSION = 5.0; MACOSX_DEPLOYMENT_TARGET = 14.0; ENABLE_APP_SANDBOX = NO; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks";}; name = Debug;};
E004 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = "com.taisei1989.inhouseagent.uitests"; PRODUCT_NAME = "$(TARGET_NAME)"; TEST_TARGET_NAME = InHouseAgent; SWIFT_VERSION = 5.0; MACOSX_DEPLOYMENT_TARGET = 14.0; ENABLE_APP_SANDBOX = NO; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks";}; name = Release;};
E005 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (E012); runOnlyForDeploymentPostprocessing = 0;};
E006 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;};
E007 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;};
E008 = {isa = PBXTargetDependency; target = A005; targetProxy = E009;};
E009 = {isa = PBXContainerItemProxy; containerPortal = A001; proxyType = 1; remoteGlobalIDString = A005; remoteInfo = InHouseAgent;};
E010 = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = InHouseAgentUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;};
E011 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UITests/InHouseAgentUITests.swift; sourceTree = "<group>";};
E012 = {isa = PBXBuildFile; fileRef = E011;};
'''
text = p.read_text()
text = text.replace('targets = (A005);', 'targets = (A005,E001);')
text = text.replace('children = (A008);', 'children = (A008,E010);')
text = text.replace('children = (A006,A007,A004,', 'children = (E011,A006,A007,A004,')
text = text.replace(' }; rootObject', ui_objects + '\n }; rootObject')
p.write_text(text)

schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
ui_suites = ['Scaffold', 'Setup', 'Runtime', 'Lifecycle', 'Notification', 'SystemNotification', 'Modern', 'Update']
for suite in ui_suites:
    scheme = f'InHouseAgent{suite}UI'
    skipped_classes = [f'{other}UITests' for other in ui_suites if other != suite]
    skipped_xml = ''.join(f'<Test Identifier="{name}"/>' for name in skipped_classes)
    schemes.joinpath(scheme + '.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A005" BuildableName="In-House Agent.app" BlueprintName="InHouseAgent" ReferencedContainer="container:InHouseAgent.xcodeproj"/>
      </BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="E001" BuildableName="InHouseAgentUITests.xctest" BlueprintName="InHouseAgentUITests" ReferencedContainer="container:InHouseAgent.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables>
      <TestableReference skipped="NO" parallelizable="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="E001" BuildableName="InHouseAgentUITests.xctest" BlueprintName="InHouseAgentUITests" ReferencedContainer="container:InHouseAgent.xcodeproj"/>
        <SkippedTests>{skipped_xml}</SkippedTests>
      </TestableReference>
    </Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A005" BuildableName="In-House Agent.app" BlueprintName="InHouseAgent" ReferencedContainer="container:InHouseAgent.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
</Scheme>
''')

schemes.joinpath('InHouseAgent.xcscheme').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A005" BuildableName="In-House Agent.app" BlueprintName="InHouseAgent" ReferencedContainer="container:InHouseAgent.xcodeproj"/>
    </BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A005" BuildableName="In-House Agent.app" BlueprintName="InHouseAgent" ReferencedContainer="container:InHouseAgent.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A005" BuildableName="In-House Agent.app" BlueprintName="InHouseAgent" ReferencedContainer="container:InHouseAgent.xcodeproj"/></BuildableProductRunnable>
  </ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
